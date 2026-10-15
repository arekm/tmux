#!/bin/sh

# Deleting lines outside the scroll region during a synchronized update moves
# up the lines below the cursor, so the client must redraw them.

PATH=/bin:/usr/bin
TERM=screen
LC_ALL=C.UTF-8
export PATH TERM LC_ALL

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)

DIR=$(mktemp -d) || exit 1
INNER="$TEST_TMUX -Lsync-dl-inner-$$ -f/dev/null"
OUTER="$TEST_TMUX -Lsync-dl-outer-$$ -f/dev/null"
EMITTER=$DIR/emitter.pl

fail()
{
	echo "$*" >&2
	exit 1
}

cleanup()
{
	$OUTER kill-server 2>/dev/null
	$INNER kill-server 2>/dev/null
	rm -rf "$DIR"
}
trap cleanup 0 1 15

wait_for_file()
{
	i=0
	while [ "$i" -lt 100 ] && [ ! -e "$1" ]; do
		sleep 0.1
		i=$((i + 1))
	done
	[ -e "$1" ] || fail "$2"
}

cat >"$EMITTER" <<'PERL'
use strict;
use warnings;
$| = 1;

my $dir = $ENV{DIR};
sub mark { open my $f, '>', "$dir/$_[0]" or die; close $f; }
sub wait_for { select undef, undef, undef, 0.01 until -e "$dir/$_[0]"; }

print "\e[2J";
print "\e[$_;1Hline $_" for 20 .. 24;
mark('painted');
wait_for('go');

print "\e[?2026h\e[3;10r\e[20;1H\e[2M\e[r\e[?2026l";
mark('done');
sleep 100;
PERL

$INNER new-session -d -s inner -x 80 -y 24 "DIR='$DIR' perl '$EMITTER'" ||
    exit 1
$INNER set-option -g status off || exit 1
$INNER set-option -g window-size manual || exit 1
$INNER set-option -as terminal-features '*:sync' || exit 1

$OUTER new-session -d -s outer -x 80 -y 24 'sleep 100' || exit 1
$OUTER set-option -g status off || exit 1
$OUTER set-option -g window-size manual || exit 1
$OUTER respawn-pane -k -t outer:0.0 \
    "$TEST_TMUX -Lsync-dl-inner-$$ -f/dev/null attach-session -t inner" ||
    exit 1

wait_for_file "$DIR/painted" "application did not paint"
sleep 1
: >"$DIR/go"
wait_for_file "$DIR/done" "application did not finish"
sleep 1

$INNER capture-pane -p -t inner:0.0 >"$DIR/inner" || exit 1
$OUTER capture-pane -p -t outer:0.0 >"$DIR/outer" || exit 1
cmp -s "$DIR/inner" "$DIR/outer" || {
	diff "$DIR/inner" "$DIR/outer" >&2
	fail "client contents differ from pane"
}
exit 0
