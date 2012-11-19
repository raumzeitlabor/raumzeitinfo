#!/usr/bin/perl

use strict;
use warnings;

use 5.10.0;

use EV;
use POSIX;
use Getopt::Long;
use JSON::XS;
use Time::Piece;
use AnyEvent;
use AnyEvent::HTTP;
use AnyEvent::IRC::Client;

use Log::Log4perl qw/:easy/;
Log::Log4perl->easy_init($INFO);

$|++;

my %opt = (
    channel => '#raumzeitlabor1',
    nick    => 'RaumZeitInfo',
    port    => 6667,
    ssl     => 0,
    server  => 'irc.hackint.eu',
    rejoin  => 3600,  # in seconds
);

my $api_url = 'http://rzl.so/w/api.php?action=query&list=recentchanges&rcprop=title|sizes|user|ids|timestamp&rclimit=10&rcend=!minor&rctoponly&format=json';

my $irc = AnyEvent::IRC::Client->new;
$irc->enable_ssl() if $opt{ssl};
$irc->connect($opt{server}, $opt{port}, { nick => $opt{nick} });

$irc->reg_cb(registered => sub { INFO "connected to ".$opt{server}; });

$irc->reg_cb(join => sub {
    my ($nick, $channel, $is_myself) = @_;
    INFO "joined channel ".$opt{channel} if $is_myself;
});

# if we get kicked, we either rejoin after some time or leave the network
$irc->reg_cb(kick => sub {
    my ($kicked_nick, $channel, $is_myself, $msg, $kicker_nick) = @_;
    return unless $is_myself;

    INFO "got kicked";
    if ($opt{rejoin}) {
        INFO "rejoining channel in ".$opt{rejoin}."s";
        my $timer; $timer = AnyEvent->timer(
            after => $opt{rejoin},
            cb => sub {
                undef $timer;
                $irc->send_srv(JOIN => ($opt{channel}));
            });
    } else {
        INFO "disconnecting";
        $irc->disconnect;
    }
});

$irc->reg_cb(disconnect => sub {
    INFO "disconnected";
    exit 1;
});

$irc->send_srv(join => ($opt{channel}));

my $lastupdate = gmtime->datetime;
my $w = AnyEvent->timer(
    interval => 300,
    cb => sub {
        my $paged_api_url = $api_url;
        $paged_api_url .= "&rcstart=".$lastupdate;
        INFO "fetching…";
        http_get $api_url, sub {
            my ($body, $hdr) = @_;
            if ($hdr->{Status} !~ /^2/) {
                WARN "HTTP error: ".$hdr->{Status}.", reason: ".$hdr->{Reason};
            }

            my $json = decode_json($body);
            INFO "fetched ".@{$json->{query}->{recentchanges}}." results";
            foreach my $page (@{$json->{query}->{recentchanges}}) {
                my $type = uc substr $page->{type}, 0, 1;
                my $diff = $page->{newlen} - $page->{oldlen};
                $diff = ($diff < 0 ? "-" : $diff == 0 ? "+-" : "+").$diff;
                my $title = $page->{title};
                my $pageid = $page->{pageid};
                my $oldid = $page->{old_revid};
                my $revid = $page->{revid};
                my $user = $page->{user};

                # mediawiki timestamps are UTC, see https://www.mediawiki.org/wiki/Manual:Timestamp
                my $time = Time::Piece->strptime($page->{timestamp}, "%Y-%m-%dT%H:%M:%SZ");
                $time += $time->localtime->tzoffset;
                $time = $time->datetime;

                my $msg = "Wiki: [$type] \"$title\" ($diff) von $user um $time Uhr http://rzl.so/w/index.php?pageid=$pageid&diff=$revid&oldid=$oldid";
                INFO $msg;
                $irc->send_chan($opt{channel}, PRIVMSG => ($opt{channel}, $msg));
            }

            $lastupdate = gmtime->datetime;
        }
    }
);

# if SIGINT is received, leave the network
my $s = AnyEvent->signal (signal => 'INT', cb => sub {
    WARN "SIGINT received, disconnecting...";
    $irc->disconnect("shutting down...");
});

EV::loop;
