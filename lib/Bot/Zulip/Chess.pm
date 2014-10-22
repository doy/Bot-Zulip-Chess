package Bot::Zulip::Chess;
use 5.020;
use feature 'signatures', 'postderef';
use experimental 'signatures', 'postderef';
use Moose;
no warnings 'experimental::signatures';
no warnings 'experimental::postderef';

use Chess::Rep;
use JSON::PP;
use Path::Class;
use Try::Tiny;
use WebService::Zulip;

has api_key => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has api_user => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has bot_name => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has streams => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    required => 1,
);

has white_player => (
    is        => 'rw',
    isa       => 'Str',
    predicate => 'has_white_player',
    clearer   => 'clear_white_player',
);

has black_player => (
    is        => 'rw',
    isa       => 'Str',
    predicate => 'has_black_player',
    clearer   => 'clear_black_player',
);

has _zulip => (
    is      => 'ro',
    isa     => 'WebService::Zulip',
    lazy    => 1,
    default => sub ($self) {
        my $zulip = WebService::Zulip->new(
            api_key  => $self->api_key,
            api_user => $self->api_user,
        );
        # XXX move this into WebService::Zulip
        $zulip->{_ua}->post('https://api.zulip.com/v1/users/me/subscriptions', {subscriptions => encode_json([ map { +{ name => $_ } } $self->streams->@* ])});
        $zulip
    },
);

has _queue => (
    is  => 'ro',
    isa => 'HashRef',
    lazy => 1,
    default => sub ($self) {
        $self->_zulip->get_message_queue
    },
);

has _chessboard => (
    is      => 'ro',
    isa     => 'Chess::Rep',
    lazy    => 1,
    default => sub ($self) {
        my $board = Chess::Rep->new;
        my $record = $self->_record_file;
        if (-e $record) {
            try {
                warn "Loading a previous game...";
                chomp(my @lines = $record->slurp);
                $self->white_player(shift @lines);
                $self->black_player(shift @lines);
                warn "Between " . $self->white_player
                   . " and " . $self->black_player;
                for my $turn (@lines) {
                    my ($white, $black) = split ' ', $turn;
                    $board->go_move($white) if $white;
                    $board->go_move($black) if $black;
                }
                my $status = $board->status;
                if ($status->{mate} || $status->{stalemate}) {
                    die "Game is over";
                }
            }
            catch {
                warn $_;
                $board = Chess::Rep->new;
            }
        }
        $board
    },
    clearer => '_clear_chessboard',
);

has _record_file => (
    is      => 'ro',
    isa     => 'Path::Class::File',
    lazy    => 1,
    default => sub { file('current.game') },
    clearer => '_clear_record_file',
);

has _temp_move => (
    is  => 'rw',
    isa => 'Str',
);

sub run ($self) {
    while (1) {
        $self->step
    }
}

sub step ($self) {
    my $res = $self->_zulip->get_new_events(
        queue_id      => $self->_queue->{queue_id},
        last_event_id => $self->_queue->{last_event_id},
        dont_block    => 'false',
    );
    for my $event ($res->{events}->@*) {
        next unless $event->{type} eq 'message';
        my $message = $event->{message};
        next if $message->{type} eq 'private';
        my $bot_name = $self->bot_name;
        my $content = $message->{content};
        next unless $content =~ s/^\@\*\*$bot_name\*\*//;
        $content =~ s/^\s*|\s*$//g;
        my $response = $self->handle_move(
            $message->{sender_full_name}, $content
        );
        my $to = $message->{type} eq 'private' ? $message->{sender_email} : $message->{display_recipient};
        $self->_zulip->send_message(
            content => $response,
            subject => $message->{subject},
            to      => $to,
            type    => $message->{type},
        );
    }
    $self->_queue->{last_event_id} = $self->_zulip->get_last_event_id($res);
}

sub handle_move ($self, $player, $move) {
    if ($move eq 'state') {
        return $self->draw_state;
    }

    if (!$self->players_turn($player)) {
        return "It's not your turn!";
    }
    else {
        if ($self->needs_new_player) {
            $self->set_new_player($player);
        }

        return try {
            if ($move eq 'resign') {
                my $msg = '@**' . $self->current_player . "** resigned";
                $self->reset_board;
                return $msg;
            }
            else {
                my $res = $self->_chessboard->go_move($move);
                my $parsed_move = $res->{san};
                if ($self->needs_new_player) {
                    $self->_temp_move($parsed_move);
                }
                else {
                    $self->_record_file->spew(
                        iomode => 'a',
                        $parsed_move . ($self->_chessboard->to_move ? "\n" : " ")
                    );
                }
                $self->draw_state;
            }
        }
        catch {
            s/ at .* line .*//r;
        };
    }
}

sub needs_new_player ($self) {
    return !$self->has_white_player || !$self->has_black_player
}

sub set_new_player ($self, $player) {
    if (!$self->has_white_player) {
        warn "$player is now playing White";
        $self->white_player($player)
    }
    elsif (!$self->has_black_player) {
        warn "$player is now playing Black";
        $self->black_player($player);
        $self->_record_file->spew(
            $self->white_player . "\n"
          . $self->black_player . "\n"
          . $self->_temp_move . " "
        );
    }
    else {
        die "Both players are already full";
    }
}

sub draw_state ($self) {
    my $board = $self->format_board =~ s/^/    /gmr;
    my $status = $self->_chessboard->status;

    if ($status->{mate}) {
        $board .= "CHECKMATE\n";
        $self->reset_board;
        return $board;
    }
    elsif ($status->{stalemate}) {
        $board .= "STALEMATE\n";
        $self->reset_board;
        return $board;
    }
    elsif ($status->{check}) {
        $board .= "CHECK\n";
    }

    my $to_move = $self->current_player;
    if ($to_move) {
        $to_move = '@**' . $to_move . '**';
    }
    else {
        $to_move = "A new opponent";
    }
    $board .= $to_move . " ("
            . ($self->_chessboard->to_move ? 'White' : 'Black')
            . ") to move\n";

    return $board;
}

sub current_player ($self) {
    my $method = $self->_chessboard->to_move ? 'white_player' : 'black_player';
    return $self->$method;
}

sub players_turn ($self, $player) {
    return if !$self->has_black_player
           && $self->has_white_player
           && $self->white_player eq $player;

    my $expected_player = $self->current_player;
    return 1 if !defined($expected_player);
    return 1 if $expected_player eq $player;

    return;
}

sub reset_board ($self) {
    $self->_record_file->move_to(time() . ".game");
    $self->_clear_record_file; # move_to updates the filename in-place
    $self->clear_white_player;
    $self->clear_black_player;
    $self->_clear_chessboard;
}

my %pieces = (
    p   => "\N{BLACK CHESS PAWN}",
    P   => "\N{WHITE CHESS PAWN}",
    n   => "\N{BLACK CHESS KNIGHT}",
    N   => "\N{WHITE CHESS KNIGHT}",
    b   => "\N{BLACK CHESS BISHOP}",
    B   => "\N{WHITE CHESS BISHOP}",
    r   => "\N{BLACK CHESS ROOK}",
    R   => "\N{WHITE CHESS ROOK}",
    q   => "\N{BLACK CHESS QUEEN}",
    Q   => "\N{WHITE CHESS QUEEN}",
    k   => "\N{BLACK CHESS KING}",
    K   => "\N{WHITE CHESS KING}",
);
sub format_board ($self) {
    my $board = $self->_chessboard->dump_pos;

    for my $piece (keys %pieces) {
        $board =~ s/$piece/$pieces{$piece}/g;
    }

    $board =~ s/\+/\N{BOX DRAWINGS LIGHT VERTICAL AND HORIZONTAL}/g;
    $board =~ s/\|-/\N{BOX DRAWINGS LIGHT VERTICAL AND RIGHT}-/g;
    $board =~ s/-\|/-\N{BOX DRAWINGS LIGHT VERTICAL AND LEFT}/g;
    $board =~ s/\|/\N{BOX DRAWINGS LIGHT VERTICAL}/g;
    $board =~ s/-/\N{BOX DRAWINGS LIGHT HORIZONTAL}/g;

    $board = "\N{BOX DRAWINGS LIGHT DOWN AND RIGHT}"
           . ("\N{BOX DRAWINGS LIGHT HORIZONTAL}\N{BOX DRAWINGS LIGHT DOWN AND HORIZONTAL}" x 7) . "\N{BOX DRAWINGS LIGHT HORIZONTAL}"
           . "\N{BOX DRAWINGS LIGHT DOWN AND LEFT}"
           . "\n" . $board . "\n"
           . "\N{BOX DRAWINGS LIGHT UP AND RIGHT}"
           . ("\N{BOX DRAWINGS LIGHT HORIZONTAL}\N{BOX DRAWINGS LIGHT UP AND HORIZONTAL}" x 7) . "\N{BOX DRAWINGS LIGHT HORIZONTAL}"
           . "\N{BOX DRAWINGS LIGHT UP AND LEFT}"
           . "\n A B C D E F G H\n";

    my @board = split "\n", $board;
    my $n = 1;
    for my $i (0..$#board) {
        my $prefix = $i % 2 == 1 && $i < 16 ? (9 - $n++) : " ";
        $board[$i] = $prefix . $board[$i];
    }

    join("\n", @board) . "\n"
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
