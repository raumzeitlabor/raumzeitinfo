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
    nick    => 'RaumZeitWiki',
    port    => 6667,
    server  => 'irc.hackint.eu',
    rejoin  => 3600,  # in seconds
);

my $init = 1;
my $feed_reader;

GetOptions(\%opt, 'channel', 'nick', 'port', 'server', 'rejoin',);

my $irc = new AnyEvent::IRC::Client;
$irc->connect($opt{server}, $opt{port}, { nick => $opt{nick}});

$irc->reg_cb(registered => sub { print DateTime->now." - Connected to ".$opt{network}."\n"; });
$irc->reg_cb(join => sub { print DateTime->now." - Joined channel ".$opt{channel}."\n"; });

# if we get kicked, we either rejoin after some time or leave the network
$irc->reg_cb(kick => sub {
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
    undef $feed_reader;
    exit 1;
});

$irc->send_srv(JOIN => ($opt{channel}));

$feed_reader = AnyEvent::Feed->new (
    url      => 'http://raumzeitlabor.de/w/index.php5?title=Spezial:Letzte_%C3%84nderungen&feed=atom',
    interval => 5,
    on_fetch => sub {
        my ($feed_reader, $new_entries, $feed, $error) = @_;

        if (defined $error) {
            warn "ERROR: $error\n";
            return;
        }

        for (@$new_entries) {
            my ($hash, $entry) = @$_;

            unless ($init) {
                my $msg = "Update: ".$entry->title." von ".$entry->author." um ".
                    $entry->modified->time." Uhr (".$entry->id.")";
                print DateTime->now." - ".$msg."\n";
                $irc->send_chan($opt{channel}, PRIVMSG => ($opt{channel}, $msg));
            }
        }

        # only post updates noticed after first refresh to prevent spam
        $init = 0 if $init;
    }
);

# if SIGINT is received, leave the network
my $w = AnyEvent->signal (signal => 'INT', cb => sub {
    print DateTime->now." - SIGINT received, disconnecting...\n";
    $irc->disconnect("shutting down...");
});

EV::loop;
