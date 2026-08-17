#!/usr/bin/env python3
import fritz

# Fritz looks for handlers in $PATH
from os import environ, pathsep
environ["PATH"] += pathsep + "./arsenal/"
environ["PATH"] += pathsep + "./arsenal/hibot/"
environ["PATH"] += pathsep + "./arsenal/sneeds_feeder/"

fritz.add_arm("AM.pl", ['chan_msg'])

fritz.Fritz(
	"chud.cyou",	# server address
	"AM",		# bot username
	["#chud"],		# channels to join
	# ["#fritz"],		# channels to join
	port=6697,
        link_socket_path='/run/fritz/AM.sock'
)
