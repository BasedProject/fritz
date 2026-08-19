#!/usr/bin/env python3
import fritz

from os import environ, pathsep
environ["PATH"] += pathsep + "./arsenal/"
environ["PATH"] += pathsep + "./arsenal/hibot/"
environ["PATH"] += pathsep + "./arsenal/sneeds_feeder/"

# fritz.add_arm("titlesniff.pl",        events=['chan_msg', 'priv_msg'])
# fritz.add_arm("bridge.pl",            events=['chan_msg'])
# fritz.add_arm("sneeds_feed_read.pl",  poll_interval=60)

fritz.add_arm("auth.pl",       events=['join', 'chan_msg', 'priv_msg'])
fritz.add_arm("tell.pl",       events=['join', 'chan_msg', 'priv_msg'])
fritz.add_arm("net.pl",        events=['chan_msg', 'priv_msg'])
fritz.add_arm("news.pl",       events=['chan_msg', 'priv_msg'], poll_interval=300)
fritz.add_arm("yt.pl",         events=['chan_msg', 'priv_msg'])
fritz.add_arm("wiki.pl",       events=['chan_msg', 'priv_msg'])
fritz.add_arm("whois.pl",      events=['chan_msg', 'priv_msg'])
fritz.add_arm("crypto.pl",     events=['chan_msg', 'priv_msg'])
fritz.add_arm("google.pl",     events=['chan_msg', 'priv_msg'])
fritz.add_arm("urban.pl",      events=['chan_msg', 'priv_msg'])
fritz.add_arm("wolfram.pl",    events=['chan_msg', 'priv_msg'])
fritz.add_arm("dice.pl",       events=['chan_msg', 'priv_msg'])
# fritz.add_arm("alarm.pl",      events=['chan_msg', 'priv_msg'], poll_interval=30)
fritz.add_arm("pick.pl",       events=['chan_msg', 'priv_msg'])
fritz.add_arm("hibot.out",     events=['chan_msg', 'priv_msg'])
fritz.add_arm("llm.pl",        events=['chan_msg', 'priv_msg'])

fritz.Fritz(
        "chud.cyou",
        "FRITZ",
        ["#chud"],
        port=6697,
        link_socket_path='/run/fritz/FRITZ.sock'
)
