#!/usr/bin/perl

use strict;
use warnings;

use EV;
use DateTime;
use AnyEvent;
use AnyEvent::Feed;
use AnyEvent::IRC::Client;

use constant {
    BOTNICK => 'RaumZeitWiki',
    IRC_NETWORK => 'irc.hackint.eu',
    IRC_CHANNEL => '#raumzeitlabor1',
    IRC_REJOIN  => 3600, # in seconds
    REFRESH_INTERVAL => 30,
};

$|++;

my $init = 1;
my $feed_reader;

my $irc = new AnyEvent::IRC::Client;
$irc->connect(IRC_NETWORK, 6667, { nick => BOTNICK });

$irc->reg_cb(registered => sub { print DateTime->now." - Connected to ".IRC_NETWORK."\n"; });
$irc->reg_cb(join => sub { print DateTime->now." - Joined channel ".IRC_CHANNEL."\n"; });

# if we get kicked, we either rejoin after some time or leave the network
$irc->reg_cb(kick => sub {
    print DateTime->now." - Got kicked";
    if (IRC_REJOIN) {
        print ", rejoining channel in ".IRC_REJOIN."s\n";
        my $timer; $timer = AnyEvent->timer(
            after => IRC_REJOIN,
            cb => sub {
                undef $timer;
                $irc->send_srv(JOIN => (IRC_CHANNEL));
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

$irc->send_srv(JOIN => (IRC_CHANNEL));

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
                $irc->send_chan(IRC_CHANNEL, PRIVMSG => (IRC_CHANNEL, $msg));
            }
        }

        # only post updates noticed after first refresh to prevent spam
        $init = 0 if $init;
    }
);

# if SIGINT is received, leave the network
my $w = AnyEvent->signal (signal => 'INT', cb => sub {
    print DateTime->now." - SIGINT received, disconnecting...";
    $irc->disconnect("shutting down...");
});

EV::loop;
