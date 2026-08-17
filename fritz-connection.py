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
	def __init__(self, server, port, use_tls, control_sock_path, replay_backlog=200):
		self.server = server
		self.port = port
		self.use_tls = use_tls
		self.control_sock_path = control_sock_path
		self.state = LinkState()
		self.upstream_reader = None
		self.upstream_writer = None
		self.control_writer = None  # currently attached control, or None
		self.backlog = collections.deque(maxlen=replay_backlog)

	async def connect_upstream(self):
		delay = 5
		while True:
			try:
				ssl_ctx = ssl.create_default_context() if self.use_tls else None
				self.upstream_reader, self.upstream_writer = await asyncio.open_connection(
					self.server, self.port, ssl=ssl_ctx)
				log.info("connected upstream to %s:%s", self.server, self.port)
				return
			except OSError as e:
				log.warning("upstream connect failed (%s), retrying in %ds", e, delay)
				await asyncio.sleep(delay)
				delay = min(delay * 2, 300)

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
	args = ap.parse_args()

	logging.basicConfig(
		level=logging.DEBUG if args.verbose else logging.INFO,
		format='%(asctime)s %(name)s %(levelname)s %(message)s',
	)

	os.makedirs(os.path.dirname(args.control_socket) or '.', exist_ok=True)

	link = IRCLink(args.server, args.port, not args.no_tls, args.control_socket)

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
