#!/usr/bin/env python3
import fritz

# Fritz looks for handlers in $PATH
from pathlib import Path
from os import environ, pathsep
environ["PATH"] += pathsep + "./arsenal/"
run_script_path = Path(__file__).resolve().parent
environ["PATH"] += pathsep + str(run_script_path / "arsenal")

# Push handler processes, referred to as "arm"s.
# Fritz manages the life time of these processes.
# The name of the program is used to deduce the named socket to communicate through.
# The choice of whether you would like to run multiple Fritz instances with one arm
#  or a monolith, is up to you.
fritz.add_arm("parrot.pl", ['chan_msg']) # Perl script repeating messages
fritz.add_arm("hate.pl", ['chan_msg'])   # Perl script adding !hate command
fritz.add_arm("hw.out", ['join'])		 # C hello world program

# Construct and run bot.
# Inverts control.
# Do not call multiple times!
fritz.Fritz(
	"127.0.0.1",	# server address
	"Fritz",		# bot username
	["#fritz"],		# channels to join
	port=6667,
	is_ssl=False
)

# NOTE: To implement your own arm, read `fritz.py`!
