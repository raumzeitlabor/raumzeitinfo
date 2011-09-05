#!/usr/bin/perl

use strict;
use warnings;

use EV;
use DateTime;
use Getopt::Long;
use AnyEvent;
use AnyEvent::Feed;
use AnyEvent::IRC::Client;

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

my @feed_reader;
my $irc = new AnyEvent::IRC::Client;
$irc->enable_ssl() if $opt{ssl};
$irc->connect($opt{server}, $opt{port}, { nick => $opt{nick} });

$irc->reg_cb(registered => sub { print DateTime->now." - Connected to ".$opt{server}."\n"; });

$irc->reg_cb(join => sub {
    my ($nick, $channel, $is_myself) = @_;
    print DateTime->now." - Joined channel ".$opt{channel}."\n" if $is_myself;
});

# if we get kicked, we either rejoin after some time or leave the network
$irc->reg_cb(kick => sub {
    my ($kicked_nick, $channel, $is_myself, $msg, $kicker_nick) = @_;
    return unless $is_myself;

    print DateTime->now." - Got kicked";
    if ($opt{rejoin}) {
        print ", rejoining channel in ".$opt{rejoin}."s\n";
        my $timer; $timer = AnyEvent->timer(
            after => $opt{rejoin},
            cb => sub {
                undef $timer;
                $irc->send_srv(JOIN => ($opt{channel}));
            });
    } else {
        print ", disconnecting\n";
        $irc->disconnect;
    }
});

$irc->reg_cb(disconnect => sub {
    print DateTime->now." Disconnected\n";
    undef @feed_reader;
    exit 1;
});

$irc->send_srv(join => ($opt{channel}));

foreach my $f (@feeds) {
    my $init = 1;
    my $reader = AnyEvent::Feed->new (
        url      => $f,
        interval => $opt{refresh},
        on_fetch => sub {
            my ($feed_reader, $new_entries, $feed, $error) = @_;

            if (defined $error) {
                warn "ERROR: $error\n";
                return;
            }

            # only post updates noticed after first refresh to prevent spam
            if ($init) { $init--; return; };

            for (@$new_entries) {
                my ($hash, $entry) = @$_;
                my $msg = "Update: \"".$entry->title."\" von ".$entry->author." um ".
                    $entry->modified->time." Uhr (".$entry->id.")";
                print DateTime->now." - ".$msg."\n";
                $irc->send_chan($opt{channel}, PRIVMSG => ($opt{channel}, $msg));
            }
        }
    );

    push @feed_reader, $reader;
}

# if SIGINT is received, leave the network
my $w = AnyEvent->signal (signal => 'INT', cb => sub {
    print DateTime->now." - SIGINT received, disconnecting...\n";
    $irc->disconnect("shutting down...");
});

EV::loop;
