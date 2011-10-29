#!/usr/bin/perl

use strict;
use warnings;

use EV;
use DateTime;
use Digest::SHA qw(sha256_hex);
use Getopt::Long;
use AnyEvent;
use AnyEvent::Feed;
use AnyEvent::IRC::Client;

use Log::Log4perl qw/:easy/;
Log::Log4perl->easy_init($INFO);

$|++;

my %opt = (
    channel => '#raumzeitlabor',
    nick    => 'RaumZeitInfo',
    port    => 6667,
    ssl     => 0,
    server  => 'irc.hackint.eu',
    rejoin  => 3600,  # in seconds
    refresh => 300,   # in seconds
);

my @feeds = (
    'http://raumzeitlabor.de/feed',
    'http://raumzeitlabor.de/w/index.php5?title=Spezial:Letzte_%C3%84nderungen&feed=atom',
);

GetOptions(\%opt, 'channel=s', 'nick=s', 'port=i', 'server=s', 'rejoin=i', 'ssl=i');

INFO 'starting up';

my @feed_reader;
my $irc = new AnyEvent::IRC::Client;
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
    undef @feed_reader;
    exit 1;
});

$irc->send_srv(join => ($opt{channel}));

my @old_entries;

foreach my $f (@feeds) {
    my $init = 1;
    my $reader = AnyEvent::Feed->new (
        url      => $f,
        interval => $opt{refresh},
        on_fetch => sub {
            my ($feed_reader, $new_entries, $feed, $error) = @_;

            if (defined $error) {
                ERROR $error;
                return;
            }

            # only post updates noticed after first refresh to prevent spam
            if ($init) { $init--; return; };

            for (@$new_entries) {
                my ($hash, $entry) = @$_;

                if (sha256_hex($entry->content) ~~ @old_entries) {
                    WARN "tried to send old item...";
                } else {
                    while (scalar(@old_entries) > 100) {
                        shift(@old_entries);
                    }

                    push(@old_entries, sha256_hex($entry->content));
                    my $msg = "Update: \"".$entry->title."\" von ".$entry->author." um ".
                        $entry->modified->set_time_zone('local')->strftime("%H:%I")
                            ." Uhr (".$entry->id.")";
                    INFO $msg;
                    $irc->send_chan($opt{channel}, PRIVMSG => ($opt{channel}, $msg));
                }
            }
        }
    );

    push @feed_reader, $reader;
}

# if SIGINT is received, leave the network
my $w = AnyEvent->signal (signal => 'INT', cb => sub {
    WARN "SIGINT received, disconnecting...";
    $irc->disconnect("shutting down...");
});

EV::loop;
