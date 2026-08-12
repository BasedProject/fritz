# Fritz
> FastCGI Relayed Internet chaT \0

Fritz is an IRC bot framework that utilizes FastCGI.

```
            IRC             FCGI
+--------+       +-------+ <----> Event Hander Process
| Server | <---> | Fritz | <----> Event Hander Process
+--------+       +-------+ <----> Event Hander Process
```

With Fritz you can implement bot behaviour in any language
that supports the FCGI protocol.
That is to say, any language that can use sockets
and especially languages that have library support,
such as but not limited to,
Ada, C/C++, Python, Perl, Node.js, Java, Tcl and many Lisp dialects.

Using Fritz, your application does not have to bother with the implementation details of IRC.
Amongst many favourable consequences, this also means that Fritz bots are long-lasting.
For example, as of writing this,
the libircclient C library has been broken for many years now;
it segvs on IPv6 connections and won't compile with up-to-date SSL support.
Now, while Python and its IRC client library
-on which the current Fritz implementation depends on-
may suffer the same fate in the future,
given any tool that supports both IRC and FCGI,
Fritz could be reimplemented under a day and your bots revived without change.

# FCGI
As mentioned, FCGI protocol is utilized for inter-process communication,
however it is used slightly differently than it would be for web development.

Each FCGI program subscribes to one or many events
(instead of corresponding to end points)
and all of them will be called in the order of registration on said event.
Examples of events would be `join`, `chan_msg` or `priv_msg`.
To see what is implemented, consult the top of the source.
The special (non-IRC) event `poll` is provided which will be invoked periodically.

The following environment variables could be defined depending on the event:
* BOTNAME (name of the Fritz instance on the server)
* USERNAME (name of the triggering user)
* CHANNEL (source chan)
* JOINED (list of currently joined chans)
* EVENT (name of the event as specifiable to Fritz)

Text of the triggering event is delievered to `stdin`.

The first line of the response is a metadata header for Fritz,
everything else is the response body.
If the header resembles a user or channel name,
it designates the target that should be messaged.
If the message body is an empty string, it shall not be posted by Fritz.
If the header is `!raw`, it signifies that the body is an IRC command that should be executed.
if the header is `!exit`, Fritz will terminate with 0.

# Usage
To run a Fritz bot, you need a run script.

There is no Fritz CLI, however a run script could easily implement one.

The commented example `run_script.py` is provided for your information.

The `arsenal/` directory contains a collection of Fritz compatible bot implementations.
