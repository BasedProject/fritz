#!/usr/bin/env python3
"""
irc-link: persistent relay between the real IRC server connection and
a local control process (Fritz.py). Owns the actual TCP/TLS socket to
the network; a control process attaches to it over a Unix domain
socket and can be killed/restarted freely without the network seeing
a disconnect.

Protocol (line-oriented, CRLF-terminated, byte-transparent IRC once
attached):

  * Only one control client is serviced at a time; a new connection
    replaces whatever was previously attached (the old one is closed).
  * irc-link answers PING itself, unconditionally, so the session
    survives even while no control is attached.
  * irc-link passively parses traffic from the server to track
    registration state (nick, joined channels) -- it never originates
    protocol traffic on its own besides PONG.
  * On a control (re)attach:
      - if the link is not yet registered (first-ever boot), lines
        from control are forwarded to the server unmodified, so
        control performs NICK/USER/JOIN exactly as if talking to the
        real server directly.
      - if the link IS already registered, any NICK/USER line from
        control is dropped (resending it would either no-op or throw
        ERR_ALREADYREGISTERED), and irc-link instead synthesizes a
        001 welcome line plus one JOIN per currently-tracked channel
        and feeds them to control. This re-fires Fritz's normal
        on_welcome/on_join handlers so it rebuilds self.nick/
        self.joined and re-dispatches the connect/join events to arms
        -- without touching the wire.
      - on_welcome's own auto-join of the configured channel list will
        still send real JOINs for channels it's already in; this is a
        harmless no-op on essentially every ircd (server just resends
        TOPIC/NAMES, doesn't re-emit a JOIN to the joiner) but is
        worth knowing about if you're on something exotic.
"""

import argparse
import asyncio
import base64
import collections
import logging
import os
import re
import signal
import ssl
import sys

log = logging.getLogger("irc-link")

WELCOME_RE     = re.compile(rb'^:(?P<server>\S+)\s+001\s+(?P<nick>\S+)\s+:')
NICK_CHANGE_RE = re.compile(rb'^:(?P<old>[^!]+)!\S+\s+NICK\s+:?(?P<new>\S+)')
JOIN_RE        = re.compile(rb'^:(?P<who>[^!]+)!\S+\s+JOIN\s+:?(?P<chan>\S+)')
SRC_NICK_RE    = re.compile(rb'^:(?P<who>[^!]+)!')
PART_RE        = re.compile(rb'^:\S+\s+PART\s+(?P<chan>\S+)')
KICK_RE        = re.compile(rb'^:\S+\s+KICK\s+(?P<chan>\S+)\s+(?P<who>\S+)')
QUIT_RE        = re.compile(rb'^:(?P<who>[^!]+)!\S+\s+QUIT')
PING_RE        = re.compile(rb'^PING\s+(?P<tok>.*)$')
OUT_REG_RE     = re.compile(rb'^(NICK|USER)\b', re.IGNORECASE)

CAP_LS_RE      = re.compile(rb'^:\S+\s+CAP\s+\S+\s+LS\s+(?P<more>\*\s+)?:(?P<caps>.*)$')
CAP_ACK_RE     = re.compile(rb'^:\S+\s+CAP\s+\S+\s+ACK\s+:?(?P<caps>.*)$')
CAP_NAK_RE     = re.compile(rb'^:\S+\s+CAP\s+\S+\s+NAK\s+:?(?P<caps>.*)$')
AUTH_CONT_RE   = re.compile(rb'^AUTHENTICATE\s+\+$')
SASL_STATUS_RE = re.compile(rb'^:\S+\s+(?P<num>90[0-8])\b')


class SASLError(Exception):
	pass


class LinkState:
	def __init__(self):
		self.registered = False
		self.nick = None
		self.joined = set()

	def observe_from_server(self, line: bytes):
		if m := WELCOME_RE.match(line):
			self.registered = True
			self.nick = m.group('nick').decode()
			return
		if m := NICK_CHANGE_RE.match(line):
			if self.nick and m.group('old').decode() == self.nick:
				self.nick = m.group('new').decode()
			return
		if m := JOIN_RE.match(line):
			if self.nick and m.group('who').decode() == self.nick:
				self.joined.add(m.group('chan').decode())
			return
		if m := PART_RE.match(line):
			if m2 := SRC_NICK_RE.match(line):
				if self.nick and m2.group('who').decode() == self.nick:
					self.joined.discard(m.group('chan').decode())
			return
		if m := KICK_RE.match(line):
			if self.nick and m.group('who').decode() == self.nick:
				self.joined.discard(m.group('chan').decode())
			return
		if m := QUIT_RE.match(line):
			if self.nick and m.group('who').decode() == self.nick:
				self.registered = False
				self.joined.clear()
			return

	def replay_lines(self, server_name: str) -> list:
		"""Lines to hand a freshly (re)attached control so it believes
		it just registered and joined, without touching the wire."""
		if not self.registered or not self.nick:
			return []
		out = [f':{server_name} 001 {self.nick} :Welcome back (relayed by irc-link)'.encode()]
		for chan in sorted(self.joined):
			out.append(f':{self.nick}!relay@irc-link JOIN :{chan}'.encode())
		return out


class IRCLink:
	def __init__(self, server, port, use_tls, control_sock_path, replay_backlog=200,
	             sasl_mechanism=None, sasl_authzid='', sasl_authcid=None,
	             sasl_cert=None, sasl_key=None, sasl_pass_file=None):
		self.server = server
		self.port = port
		self.use_tls = use_tls
		self.control_sock_path = control_sock_path
		self.sasl_mechanism = sasl_mechanism  # 'external' | 'plain' | None
		self.sasl_authzid = sasl_authzid
		self.sasl_authcid = sasl_authcid
		self.sasl_cert = sasl_cert
		self.sasl_key = sasl_key
		self.sasl_pass_file = sasl_pass_file
		self.state = LinkState()
		self.upstream_reader = None
		self.upstream_writer = None
		self.control_writer = None  # currently attached control, or None
		self.backlog = collections.deque(maxlen=replay_backlog)

	async def connect_upstream(self):
		delay = 5
		while True:
			try:
				ssl_ctx = None
				if self.use_tls:
					ssl_ctx = ssl.create_default_context()
					if self.sasl_cert:
						ssl_ctx.load_cert_chain(self.sasl_cert, self.sasl_key)
				self.upstream_reader, self.upstream_writer = await asyncio.open_connection(
					self.server, self.port, ssl=ssl_ctx)
				log.info("connected upstream to %s:%s", self.server, self.port)
				if self.sasl_mechanism:
					await self.do_sasl()
				return
			except (OSError, SASLError, ConnectionError) as e:
				log.warning("upstream connect/auth failed (%s), retrying in %ds", e, delay)
				if self.upstream_writer is not None:
					self.upstream_writer.close()
				await asyncio.sleep(delay)
				delay = min(delay * 2, 300)

	async def _readline_raw(self):
		line = await self.upstream_reader.readline()
		if not line:
			raise ConnectionError("upstream closed during SASL")
		return line.rstrip(b'\r\n')

	async def _send_authenticate(self, payload: bytes):
		w = self.upstream_writer
		b64 = base64.b64encode(payload)
		if not b64:
			w.write(b'AUTHENTICATE +\r\n')
			await w.drain()
			return
		for i in range(0, len(b64), 400):
			w.write(b'AUTHENTICATE ' + b64[i:i + 400] + b'\r\n')
			await w.drain()
		if len(b64) % 400 == 0:
			# exact multiple of the 400-byte chunk size needs an
			# explicit empty final line to terminate the payload
			w.write(b'AUTHENTICATE +\r\n')
			await w.drain()

	def _sasl_payload(self, mech: str) -> bytes:
		if mech == 'EXTERNAL':
			return self.sasl_authzid.encode()
		if mech == 'PLAIN':
			with open(self.sasl_pass_file) as f:
				passwd = f.readline().rstrip('\n')
			authcid = self.sasl_authcid or self.sasl_authzid
			return b'\0'.join((self.sasl_authzid.encode(), authcid.encode(), passwd.encode()))
		raise ValueError(f"unsupported SASL mechanism: {mech}")

	async def do_sasl(self):
		w = self.upstream_writer
		w.write(b'CAP LS 302\r\n')
		await w.drain()

		caps = b''
		while True:
			line = await self._readline_raw()
			m = CAP_LS_RE.match(line)
			if not m:
				continue
			caps += b' ' + m.group('caps')
			if not m.group('more'):
				break

		sasl_cap = None
		for tok in caps.split():
			if tok == b'sasl' or tok.startswith(b'sasl='):
				sasl_cap = tok
				break

		if sasl_cap is None:
			log.warning("server does not advertise sasl cap, proceeding unauthenticated")
			w.write(b'CAP END\r\n')
			await w.drain()
			return

		# CAP LS 302 lists supported mechanisms as the cap's value
		# (e.g. b'sasl=EXTERNAL,PLAIN'); a bare b'sasl' (older/plain
		# CAP LS) means the server didn't advertise a mechanism list,
		# so don't gate on it -- let the server itself reject via
		# AUTHENTICATE/904 if unsupported.
		if b'=' in sasl_cap:
			offered = sasl_cap.split(b'=', 1)[1].split(b',')
			if self.sasl_mechanism.upper().encode() not in offered:
				raise SASLError(
					f"server offers SASL mechanisms {offered!r}, "
					f"not {self.sasl_mechanism.upper()!r}")

		w.write(b'CAP REQ :sasl\r\n')
		await w.drain()
		while True:
			line = await self._readline_raw()
			if CAP_ACK_RE.match(line):
				break
			if CAP_NAK_RE.match(line):
				raise SASLError("server NAKed CAP REQ :sasl")

		mech = self.sasl_mechanism.upper()
		w.write(b'AUTHENTICATE ' + mech.encode() + b'\r\n')
		await w.drain()
		while True:
			line = await self._readline_raw()
			if AUTH_CONT_RE.match(line):
				break
			if SASL_STATUS_RE.match(line):
				raise SASLError(f"SASL rejected before continuation: {line!r}")

		await self._send_authenticate(self._sasl_payload(mech))

		while True:
			line = await self._readline_raw()
			m = SASL_STATUS_RE.match(line)
			if not m:
				continue
			num = m.group('num')
			if num == b'903':
				log.info("SASL %s authentication succeeded", mech)
				break
			raise SASLError(f"SASL authentication failed ({num.decode()}): {line!r}")

		w.write(b'CAP END\r\n')
		await w.drain()

	async def upstream_reader_loop(self):
		while True:
			try:
				line = await self.upstream_reader.readline()
			except (ConnectionError, OSError) as e:
				log.warning("upstream read error: %s", e)
				line = b''

			if not line:
				log.warning("upstream connection lost, reconnecting")
				self.state.registered = False
				await self.connect_upstream()
				continue

			line = line.rstrip(b'\r\n')
			if not line:
				continue

			self.state.observe_from_server(line)
			self.backlog.append(line)

			if m := PING_RE.match(line):
				# keep the session alive independent of whether control
				# is attached right now
				self.upstream_writer.write(b'PONG ' + m.group('tok') + b'\r\n')
				await self.upstream_writer.drain()

			if self.control_writer is not None:
				try:
					self.control_writer.write(line + b'\r\n')
					await self.control_writer.drain()
				except (ConnectionError, OSError):
					self.control_writer = None

	async def handle_control(self, reader, writer):
		if self.control_writer is not None and self.control_writer is not writer:
			log.info("new control attached, closing previous one")
			try:
				self.control_writer.close()
			except Exception:
				pass
		self.control_writer = writer
		peer = writer.get_extra_info('peername')
		log.info("control attached (%s)", peer)

		replay = self.state.replay_lines(self.server)
		for line in replay:
			writer.write(line + b'\r\n')
		if replay:
			await writer.drain()

		try:
			while True:
				line = await reader.readline()
				if not line:
					break
				line = line.rstrip(b'\r\n')
				if not line:
					continue
				if self.state.registered and OUT_REG_RE.match(line):
					log.debug("dropping redundant registration line from control: %r", line)
					continue
				if self.upstream_writer is not None:
					self.upstream_writer.write(line + b'\r\n')
					await self.upstream_writer.drain()
		except (ConnectionError, OSError):
			pass
		finally:
			if self.control_writer is writer:
				self.control_writer = None
			log.info("control detached (%s)", peer)

	async def run(self):
		await self.connect_upstream()
		if os.path.exists(self.control_sock_path):
			os.unlink(self.control_sock_path)
		server = await asyncio.start_unix_server(self.handle_control, path=self.control_sock_path)
		os.chmod(self.control_sock_path, 0o600)
		log.info("control socket listening at %s", self.control_sock_path)
		async with server:
			await asyncio.gather(self.upstream_reader_loop(), server.serve_forever())


def main():
	ap = argparse.ArgumentParser(description=__doc__)
	ap.add_argument('--server', required=True)
	ap.add_argument('--port', type=int, default=6697)
	ap.add_argument('--no-tls', action='store_true')
	ap.add_argument('--control-socket') # no default on purpose
	ap.add_argument('-v', '--verbose', action='store_true')
	ap.add_argument('--sasl-mechanism', choices=('external', 'plain'),
	                 help="enable SASL auth during registration")
	ap.add_argument('--sasl-authzid', default='',
	                 help="SASL authzid (optional for both mechanisms)")
	ap.add_argument('--sasl-authcid',
	                 help="SASL authcid for PLAIN (defaults to --sasl-authzid)")
	ap.add_argument('--sasl-cert', help="client cert for TLS + SASL EXTERNAL")
	ap.add_argument('--sasl-key', help="client key for TLS + SASL EXTERNAL")
	ap.add_argument('--sasl-pass-file',
	                 help="file whose first line is the SASL PLAIN password "
	                      "(kept out of argv/ps on purpose)")
	args = ap.parse_args()

	logging.basicConfig(
		level=logging.DEBUG if args.verbose else logging.INFO,
		format='%(asctime)s %(name)s %(levelname)s %(message)s',
	)

	if args.sasl_mechanism == 'external':
		if args.no_tls or not args.sasl_cert:
			ap.error("--sasl-mechanism external requires TLS plus --sasl-cert "
			         "(unified PEM ok, or --sasl-cert/--sasl-key split)")
	elif args.sasl_mechanism == 'plain':
		if not args.sasl_pass_file:
			ap.error("--sasl-mechanism plain requires --sasl-pass-file")

	os.makedirs(os.path.dirname(args.control_socket) or '.', exist_ok=True)

	link = IRCLink(args.server, args.port, not args.no_tls, args.control_socket,
	               sasl_mechanism=args.sasl_mechanism,
	               sasl_authzid=args.sasl_authzid,
	               sasl_authcid=args.sasl_authcid,
	               sasl_cert=args.sasl_cert,
	               sasl_key=args.sasl_key,
	               sasl_pass_file=args.sasl_pass_file)

	loop = asyncio.new_event_loop()
	asyncio.set_event_loop(loop)

	def shutdown(*_):
		log.info("shutting down")
		for task in asyncio.all_tasks(loop):
			task.cancel()

	for sig in (signal.SIGTERM, signal.SIGINT):
		loop.add_signal_handler(sig, shutdown)

	try:
		loop.run_until_complete(link.run())
	except asyncio.CancelledError:
		pass
	finally:
		if os.path.exists(args.control_socket):
			os.unlink(args.control_socket)


if __name__ == '__main__':
	main()
