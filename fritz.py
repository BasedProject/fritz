import ssl
import heapq
import atexit
import signal
import traceback
from dataclasses import dataclass, field
from os import fork, execvp, path, unlink, setpgid, kill
from time import time, sleep, monotonic
from fcgi_client import FastCGIClient
from irc.client import SimpleIRCClient, ServerConnectionError
from irc.connection import Factory

# --- ------- ---
# --- Private ---
# --- ------- ---

arms = []
event_queues = {
	'connect'  : [],
	'join'	   : [],
	'part'	   : [],
	'quit'	   : [],
	'priv_msg' : [],
	'chan_msg' : [],
}

# Poll scheduling
@dataclass(order=True)
class PollingTask:
	next_run : float
	interval : float
	arm      : object = field(compare=False)

poll_scheduling_heap = []

def add_polling(interval, arm):
	now = monotonic()
	heapq.heappush(poll_scheduling_heap, PollingTask(
		next_run=now+interval,
		interval=interval,
		arm=arm,
	))

# FCGI process wrapper
class Fritz_arm:
	def wait_for_socket(self, sock_path, timeout=0.5, interval=0.05):
		deadline = monotonic() + timeout
		while monotonic() < deadline:
			if path.exists(sock_path): return True
			sleep(interval)
		return False
	def __init__(self, name : str):
		self.name	   = name
		self.sock_path = name.replace('.', '-') + ".sock"
		self.pid = fork()
		if self.pid == 0:
			execvp(self.name, f"{name}".split(' '))
		else:
			if not self.wait_for_socket(self.sock_path):
				raise RuntimeError(
					f"Fritz_arm({self.name!r}): socket {self.sock_path!r} "
					f"was not created within timeout (child pid {self.pid})"
				)
			self.client = FastCGIClient(f"unix://{self.sock_path}")
	def request(self, params={}, stdin=b''):
		return self.client.request(params, stdin)

def my_atexit():
	def unlink_sockets():
		for a in arms:
			try: unlink(a.sock_path)
			except: traceback.print_exc()
	def kill_children():
		for a in arms:
			kill(a.pid, signal.SIGTERM)
	unlink_sockets()
	kill_children()

def handle_event(event : str, data : {}) -> str | None:
	message = ''

	if "MESSAGE" in data:
		message = data["MESSAGE"].encode()
		del data["MESSAGE"] # remove from passed env

	for arm in event_queues[event]:
		response = arm.request(data, message)
		if response is None:
			print(f"!! 'None' response recieved from '{arm.name}'")
			continue
		r = response.decode(errors='ignore').strip()
		print("<< " + r)
		yield r

	yield None

# --- ------ ---
# --- Public ---
# --- ------ ---

def add_arm(name, events=[], poll_interval=None):
	arm = Fritz_arm(name)
	arms.append(arm)
	for event in events:
		event_queues[event].append(arm)
	if poll_interval != None:
		add_polling(poll_interval, arm)

class Fritz(SimpleIRCClient):
	def __init__(self, server, nick, auto_join_list, port=6697, is_ssl=True):
		def ssl_wrapper(sock):
			context = ssl.create_default_context()
			return context.wrap_socket(sock, server_hostname=server)

		atexit.register(my_atexit)

		self.nick			= nick
		self.auto_join_list = auto_join_list
		self.joined			= []

		if port < 6690:
			is_ssl = False

		factory = Factory(wrapper=ssl_wrapper) if is_ssl else Factory()

		super().__init__()
		try:
			super().connect(
				server,
				port,
				nick,
				connect_factory = factory
			)
		except Exception as e:
			print(f"!! Failed to establish connection: '{e}'.")
			exit(1)

		self.run()

	# === Privmsg humilation ritual ===
	# The library provided privmsg() is a foot gun:
	#  * for messages which are too long for the IRC protocol,
	#     it does not perform auto splitting to handle long messages,
	#     but throws instead
	#  * for messages which are short enough for IRC,
	#     but for _some fucking reason_ too long for the library,
	#     it fails silently
	#     (bug report pending) # XXX insert link
	def privmsg(self, target : str, message : str):
		safe_magick_lenght = 160
		n_free_bytes = safe_magick_lenght - len('PRIVMSG  :\r\n') - len(target.encode('utf-8'))
		raw_message = message.encode('utf-8')
		for m in [raw_message[i:i+n_free_bytes] for i in range(0, len(raw_message), n_free_bytes)]:
			self.connection.privmsg(target, m.decode('utf-8', errors='ignore'))
	# === === ===

	def insert_global_data(self, data : {str : str}, event_name : str) -> {str : str}:
		data["BOTNAME"] = self.nick
		data["JOINED"]  = ":".join(self.joined)
		data["EVENT"]   = event_name
		return data

	def handle_response(self, response : str | None):
		print(response)
		if response is None: return
		if response == "": return
		try:
			lines	 = response.splitlines()
			metadata = lines[0].strip()
			target	 = metadata
			body	 = lines[1:]
		except:
			print("!! Invalid response.")
			return
		if metadata == "!raw":
			for l in body:
				self.connection.send_raw(l)
			return
		if metadata == "!exit":
			exit(0)
		for l in body:
			self.privmsg(target, l)

	def run_irc_event_handler(self, event_name: str, data: {}):
		print(f">> {event_name}: {{{data}}}")

		data = self.insert_global_data(data, event_name)

		for response in handle_event(event_name, data):
			self.handle_response(response)

	def do_poll(self):
		now = monotonic()
		if poll_scheduling_heap and poll_scheduling_heap[0].next_run <= now:
			task = heapq.heappop(poll_scheduling_heap)
			print(f">> poll: {{{task.arm.name}}}")
			task.next_run = now + task.interval
			heapq.heappush(poll_scheduling_heap, task)
			data = self.insert_global_data({}, 'poll')
			response = task.arm.request(data, '')
			if response != None: response = response.decode(errors='ignore').strip()
			self.handle_response(response)

	def run(self):
		while self.connection.is_connected():
			self.reactor.process_once(timeout=.2)
			self.do_poll()

	# === Common event handlers ===

	def on_welcome(self, connection, event):
		for chan in self.auto_join_list: connection.join(chan)
		print(f"-- Fritz online @ {connection.server_address}")
		self.run_irc_event_handler("connect", {})

	def on_join(self, connection, event):
		if event.source.nick == self.nick:
			self.joined.append(event.target)
		records = {
			"USERNAME" : event.source.nick,
			"CHANNEL"  : event.target,
		}
		self.run_irc_event_handler("join", records)

	def on_pubmsg(self, connection, event):
		records = {
			"USERNAME" : event.source.nick,
			"CHANNEL"  : event.target,
			"MESSAGE"  : event.arguments[0],
		}
		self.run_irc_event_handler("chan_msg", records)

	def on_privmsg(self, connection, event):
		records = {
			"USERNAME" : event.source.nick,
			"CHANNEL"  : event.source.nick,
			"MESSAGE"  : event.arguments[0],
		}
		self.run_irc_event_handler("priv_msg", records)

	def on_part(self, connection, event):
		records = {
			"USERNAME" : event.source.nick,
			"CHANNEL"  : event.target,
		}
		self.run_irc_event_handler("part", records)

	def on_quit(self, connection, event):
		# NOTE: does NOT fire when executing QUIT, but disconnect does
		records = {
			"MESSAGE" : event.arguments[0] if event.arguments else "",
		}
		self.run_irc_event_handler("quit", records)
