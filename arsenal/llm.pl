#!/usr/bin/perl
#
# llm.pl - Fritz FCGI arm: local LLM conversation + web-scrape tool
#
# Subscribes to chan_msg / priv_msg. Triggers on ".ai <text>" or the
# bot being addressed by name ("botname: text" / "botname, text").
# Talks to a persistent llama-server instance over an AF_UNIX socket
# (see fritz-llm.service). Per-channel/per-user history is kept as a
# flat JSON array on disk, capped at HISTORY_MAX turns.
#
use strict;
use warnings;
use FCGI;
use IO::Socket::UNIX;
use JSON::PP qw(encode_json decode_json);

use constant {
    LLM_SOCKET          => '/run/llm/llm.sock',
    HISTORY_DIR         => '/var/www/fritz/history',
    HISTORY_MAX         => 100,   # stored turns (user+assistant pairs count individually)
    MAX_TOOL_ITERATIONS => 3,
    SCRAPE_CHAR_LIMIT   => 8000,  # ~2000 tokens, rough 4 chars/token budget
    SCRAPE_TIMEOUT      => 15,
    LLM_SOCKET_TIMEOUT  => 60,    # connect+read timeout for the llama-server socket
    SYSTEM_PROMPT       => <<'EOS',
You are a knowledgeable, direct conversational participant in an IRC
channel. Engage substantively with technical and detailed questions;
don't pad short questions with unnecessary caveats. You may use the
scrape_url tool to read a web page when it would materially improve
your answer.
EOS
};

my $TOOLS = [{
    type => 'function',
    function => {
        name        => 'scrape_url',
        description => 'Fetch a web page and return its extracted plain text content.',
        parameters  => {
            type       => 'object',
            properties => {
                url => { type => 'string', description => 'The URL to fetch' },
            },
            required => ['url'],
        },
    },
}];

# fritz.py's add_arm() spawns this script and then waits for it to create
# its own named FCGI socket before treating the arm as up -- it does not
# hand down a pre-bound socket the way a classic FCGI webserver would.
# Naming convention matches the other arms: "llm.pl" -> "llm-pl.sock".
my $socket_path = "llm-pl.sock";
my $socket      = FCGI::OpenSocket($socket_path, 5);
my $request     = FCGI::Request(\*STDIN, \*STDOUT, \*STDERR, \%ENV, $socket);

while ($request->Accept() >= 0) {
    eval { handle_request() };
    warn "llm arm: $@" if $@;
}

exit 0;

sub handle_request {
    my $event   = $ENV{EVENT}    // '';
    my $channel = $ENV{CHANNEL}  // '';
    my $user    = $ENV{USERNAME} // '';
    my $botname = $ENV{BOTNAME}  // '';

    local $/;
    my $text = <STDIN> // '';
    chomp $text;

    my $target = length($channel) ? $channel : $user;
    my $prompt = extract_prompt($text, $botname);

    if ($event !~ /^(?:chan_msg|priv_msg)$/ || !defined $prompt || $prompt eq '') {
        print "$target\n";
        return;
    }

    # Channels and DMs get separate history files; a channel's history
    # is shared across participants (matches the shared-context model
    # of an IRC channel).
    my $history_key  = length($channel) ? $channel : "user:$user";
    my $history_file = history_path($history_key);
    my $history      = load_history($history_file);

    push @$history, { role => 'user', content => $prompt };

    my $reply = converse($history);
    push @$history, { role => 'assistant', content => $reply };

    trim_history($history);
    save_history($history_file, $history);

    print "$target\n$reply\n";
}

# Match ".ai <text>" or "<botname>[:,] <text>"
sub extract_prompt {
    my ($text, $botname) = @_;
    return $1 if $text =~ /^\.ai\s+(.+)$/s;
    if (length $botname) {
        my $quoted = quotemeta $botname;
        return $1 if $text =~ /^\Q$botname\E\s*[:,]\s*(.+)$/si;
    }
    return undef;
}

sub history_path {
    my ($key) = @_;
    (my $safe = $key) =~ s{[^A-Za-z0-9_.-]}{_}g;
    return HISTORY_DIR . "/$safe.json";
}

sub load_history {
    my ($path) = @_;
    return [] unless -e $path;
    open my $fh, '<', $path or return [];
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $data = eval { decode_json($raw) };
    return (ref $data eq 'ARRAY') ? $data : [];
}

sub save_history {
    my ($path, $history) = @_;
    open my $fh, '>', $path or die "can't write $path: $!";
    print $fh encode_json($history);
    close $fh;
}

sub trim_history {
    my ($history) = @_;
    splice(@$history, 0, @$history - HISTORY_MAX) if @$history > HISTORY_MAX;
}

# Run the chat-completion / tool-call loop against llama-server.
# Returns the final assistant text. $history is NOT mutated here;
# caller appends the final assistant turn itself.
sub converse {
    my ($history) = @_;
    my @messages = ({ role => 'system', content => SYSTEM_PROMPT }, @$history);

    for (1 .. MAX_TOOL_ITERATIONS) {
        my $resp   = llm_chat(\@messages);
        my $choice = $resp->{choices}[0]{message};

        if (my $calls = $choice->{tool_calls}) {
            push @messages, $choice;
            for my $call (@$calls) {
                my $result = dispatch_tool($call);
                push @messages, {
                    role         => 'tool',
                    tool_call_id => $call->{id},
                    content      => $result,
                };
            }
            next;
        }

        return $choice->{content} // '(no response)';
    }

    return "(gave up after too many tool calls)";
}

sub dispatch_tool {
    my ($call) = @_;
    my $name = $call->{function}{name} // '';
    my $args = eval { decode_json($call->{function}{arguments} // '{}') } // {};

    return encode_json({ error => "unknown tool $name" }) unless $name eq 'scrape_url';
    return encode_json({ error => 'missing url' })       unless $args->{url};

    return scrape_url($args->{url});
}

sub scrape_url {
    my ($url) = @_;
    return "invalid url" unless $url =~ m{^https?://};

    my $safe_url = $url;
    $safe_url =~ s/'/'\\''/g;

    my $text = qx{timeout ${\SCRAPE_TIMEOUT} w3m -dump -cols 100 '$safe_url' 2>/dev/null};
    return "failed to fetch $url" unless defined $text && length $text;

    $text = substr($text, 0, SCRAPE_CHAR_LIMIT) if length($text) > SCRAPE_CHAR_LIMIT;
    return $text;
}

# POST a chat-completion request to llama-server over the AF_UNIX socket
# and return the decoded JSON response.
sub llm_chat {
    my ($messages) = @_;

    my $payload = encode_json({
        messages    => $messages,
        tools       => $TOOLS,
        temperature => 0.65,
        max_tokens  => 1024,
    });

    # Critical: Content-Length must be the number of *bytes* on the wire.
    # JSON::PP may return a string with the UTF-8 flag set.
    utf8::encode($payload) if utf8::is_utf8($payload);

    my $sock = IO::Socket::UNIX->new(
        Peer    => LLM_SOCKET,
        Type    => SOCK_STREAM,
        Timeout => LLM_SOCKET_TIMEOUT,
    ) or die "connect to ${\LLM_SOCKET} failed: $!";

    my $req = "POST /v1/chat/completions HTTP/1.1\r\n"
            . "Host: localhost\r\n"
            . "Content-Type: application/json\r\n"
            . "Content-Length: " . length($payload) . "\r\n"
            . "Connection: close\r\n\r\n"
            . $payload;

    print $sock $req or die "write to llm-runtime failed: $!";
    $sock->shutdown(1);

    local $/;
    my $raw = <$sock>;
    close $sock;

    die "empty response from llm-runtime" unless defined $raw && length $raw;

    my ($head, $body) = split /\r?\n\r?\n/, $raw, 2;
    $body //= '';

    my ($status) = $head =~ m{^HTTP/1\.[01]\s+(\d+)};
    die "unparseable status line from llm-runtime; first 400 bytes:\n"
      . substr($raw, 0, 400) unless defined $status;

    my ($te) = $head =~ /^Transfer-Encoding:\s*([^\r\n]+)/mi;
    my ($cl) = $head =~ /^Content-Length:\s*(\d+)/mi;

    if (defined $cl) {
        $body = substr($body, 0, $cl);
    }
    elsif (defined $te && $te =~ /\bchunked\b/i) {
        $body = dechunk($body);
    }

    if ($status !~ /^2/) {
        die "llm-runtime returned HTTP $status:\n"
          . (length($body) ? $body : "(empty body)\n--- head ---\n$head");
    }

    unless (length $body) {
        die "empty body from llm-runtime despite HTTP $status\n"
          . "--- response head ---\n$head\n"
          . "--- first 300 bytes of raw response ---\n"
          . substr($raw, 0, 300) . "\n"
          . "--- length(raw)=" . length($raw)
          . " length(body after framing)=" . length($body) . " ---\n";
    }

    my $decoded = eval { decode_json($body) };
    die "bad JSON from llm-runtime (HTTP $status): $@\nbody was:\n$body" if $@;

    return $decoded;
}

sub dechunk {
    my ($data) = @_;
    return $data unless defined $data && length $data;

    # Quick reject: real chunked bodies start with a hex size
    return $data unless $data =~ /\A[0-9A-Fa-f]+(?:;[^\r\n]*)?\r?\n/;

    my $out = '';
    pos($data) = 0;

    while ($data =~ /\G([0-9A-Fa-f]+)(?:;[^\r\n]*)?\r?\n/gc) {
        my $len = hex($1);
        last if $len == 0;

        # Not enough data left → treat as non-chunked / malformed
        return $data if pos($data) + $len > length($data);

        $out .= substr($data, pos($data), $len);
        pos($data) += $len;

        # Optional trailing CRLF after the chunk data
        if ($data =~ /\G\r?\n/gc) {
            # consumed
        }
    }

    return length($out) ? $out : $data;
}
