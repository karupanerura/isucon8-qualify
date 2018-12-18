package Torb::Web;
use strict;
use warnings;
use utf8;
use feature qw/state/;

use Kossy;
use Kossy::Connection;

use JSON::XS 3.00 ();
use DBIx::Sunny;
use Plack::Session;
use Plack::Response;
use Time::Moment;
use Digest::SHA qw/sha256_hex/;
use List::Util qw/min uniq shuffle/;
use Time::HiRes qw/usleep/;
use Redis::Fast;
use Encode qw/encode_utf8 decode_utf8/;
use File::Spec;

use constant RANKS => qw/S A B C/;

my %SHEETS_MAP = (
    S => 50,
    A => 150,
    B => 300,
    C => 500,
);

my %PRICE_MAP = (
    S => 5000,
    A => 3000,
    B => 1000,
    C => 0,
);

sub _nop {}

sub _report_err {
    my (undef, $err) = @_;
    warn $err if $err;
}

{
    my $_JSON_RAW = JSON::XS->new;
    sub _encode_json_for_html { Kossy::Connection->escape_json($_JSON_RAW->encode(@_)) }

    my $_JSON_UTF8 = JSON::XS->new->utf8;
    sub _encode_json_utf8 { $_JSON_UTF8->encode(@_) }
    sub _decode_json_utf8 { $_JSON_UTF8->decode(@_) }
}

filter login_required => sub {
    my $app = shift;
    return sub {
        my ($self, $c) = @_;

        my $user_id = $self->get_login_user_id($c);
        return $self->res_error($c, login_required => 401) unless $user_id;

        $app->($self, $c);
    };
};

filter fillin_user => sub {
    my $app = shift;
    return sub {
        my ($self, $c) = @_;

        my $user = $self->get_login_user($c);
        $c->stash->{user} = $user if $user;

        $app->($self, $c);
    };
};

filter allow_json_request => sub {
    my $app = shift;
    return sub {
        my ($self, $c) = @_;
        $c->env->{'kossy.request.parse_json_body'} = 1;
        $app->($self, $c);
    };
};

sub dbh {
    my $self = shift;
    $self->{_dbh}{$$} ||= do {
        my $dsn = "dbi:mysql:database=$ENV{DB_DATABASE};host=$ENV{DB_HOST};port=$ENV{DB_PORT}";
        DBIx::Sunny->connect($dsn, $ENV{DB_USER}, $ENV{DB_PASS}, {
            mysql_enable_utf8mb4 => 1,
            mysql_auto_reconnect => 1,
        });
    };
}

sub redis {
    my $self = shift;
    $self->{_redis}{$$} ||= do {
        Redis::Fast->new(
            server    => "$ENV{REDIS_HOST}:6379",
            reconnect => 1,
            every     => 100_000,
            encoding  => undef,
        );
    };
}

get '/' => [qw/fillin_user/] => sub {
    my ($self, $c) = @_;

    my @events = map { $self->sanitize_event($_) } $self->get_events();
    return $c->render('index.tx', {
        events      => \@events,
        encode_json => \&_encode_json_for_html,
    });
};

get '/initialize' => sub {
    my ($self, $c) = @_;

    system+File::Spec->catfile($self->root_dir, '../../db/init.sh');
    die $! if $? != 0;

    $c->env->{'psgix.harakiri.commit'} = 1;

    for my $file (glob '/tmp/report_all_*.csv') {
        unlink $file;
    }
    for my $file (glob '/tmp/report_*.csv') {
        my ($event_id) = $file =~ m!^/tmp/report_([0-9]+).csv$!;
        unlink $file if $event_id > 18;
    }

    $self->redis->flushall();

    my $users = $self->dbh->select_all('SELECT * FROM users ORDER BY id ASC');
    for my $user (@$users) {
        my $id = $user->{id};
        $self->redis->hset("userauth:$user->{login_name}", $user->{pass_hash}, $id, \&_report_err);
        $self->redis->set("total_price:$id" => 0, \&_report_err);
        $self->redis->set("nickname:$id"    => encode_utf8($user->{nickname}), \&_report_err);
        $self->redis->wait_all_responses() if $id % 1000 == 0;
    }
    $self->redis->set(last_user_id => $users->[-1]->{id}, \&_report_err);
    $self->redis->wait_all_responses();

    my $events = $self->dbh->select_all('SELECT * FROM events ORDER BY id ASC');
    for my $event (@$events) {
        $event->{id} += 0;
        $event->{public} = delete $event->{public_fg} ? JSON::XS::true : JSON::XS::false;
        $event->{closed} = delete $event->{closed_fg} ? JSON::XS::true : JSON::XS::false;
        $event->{price} += 0;
        $event->{total} = 1000;
        $event->{remains} = 1000;
        $event->{sheets} = {
            map {
                $_ => {
                    total   => 0+$SHEETS_MAP{$_},
                    remains => 0+$SHEETS_MAP{$_},
                    price   => $event->{price}+$PRICE_MAP{$_},
                },
            } RANKS,
        };
    }
    $self->redis->set("last_event_id", 0+$events->[-1]->{id});
    $self->create_initial_event_states($events);

    {
        my $rid = $self->dbh->select_one('SELECT MIN(r.id) FROM reservations r INNER JOIN events e ON r.event_id = e.id WHERE NOT ((e.closed_fg = 0 AND r.canceled_at IS NOT NULL) OR e.closed_fg = 1)');
        my $res = $self->render_report_csv('SELECT * FROM reservations WHERE id < ? ORDER BY id ASC', $rid);
        $res->finalize()->(sub {
            my $header_line = shift;
            open my $fh, '>', "/tmp/report_all_prefix_$rid.csv" or die $!;
            return Plack::Util::inline_object(
                write => sub {
                    print {$fh} @_;
                },
                close => sub {
                    close $fh or die $!;
                },
            );
        });
    };

    {
        my %event_reserved_count;
        my %user_total_price;
        my %reservation;
        my %user_reservations;

        my %event_map = map { $_->{id} => $_ } @{ $self->dbh->select_all('SELECT * FROM events') };
        my %sheets_map = %{ $self->sheets_map };

        {
            my $sth = $self->dbh->prepare('SELECT * FROM reservations ORDER BY updated_at, id ASC', { mysql_use_result => 1 });
            $sth->execute();

            my $i = 0;
            my $rid;
            while (my $r = $sth->fetchrow_hashref) {
                $rid = $r->{id};
                push @{ $user_reservations{$r->{user_id}} } => $r->{updated_at}.$r->{id}, $r->{id};
                splice @{ $user_reservations{$r->{user_id}} }, 0, 2 if @{ $user_reservations{$r->{user_id}} } > 10;
                next if $r->{canceled_at};

                my $event = $event_map{$r->{event_id}};
                my $sheet = $sheets_map{$r->{sheet_id}};
                $event_reserved_count{$event->{id}}{$sheet->{rank}}++;
                $user_total_price{$r->{user_id}} += $event->{price} + $sheet->{price};
                $reservation{$event->{id}}{$sheet->{id}} = _encode_json_utf8({
                    num         => 0+$sheet->{num},
                    user_id     => 0+$r->{user_id},
                    reserved_at => 0+$r->{reserved_at},
                    log_id      => $r->{id},
                });
                $self->redis->lrem("free_sheets:$event->{id}:$sheet->{rank}", 0, $sheet->{num}, \&_report_err);
                $self->redis->wait_all_responses() if $i++ % 1000 == 0;
            }
            $self->redis->set(last_rid => $rid, \&_report_err);

            $sth->finish();
            $self->redis->wait_all_responses();
        };

        for my $event_id (keys %event_map) {
            $self->redis->hmset("reserved_count:$event_id", (map { ($_, $event_reserved_count{$event_id}{$_}) } RANKS), \&_report_err) if exists $event_reserved_count{$event_id};
            $self->redis->hmset("reservation:$event_id", (map { ($_, $reservation{$event_id}{$_}) } keys %{ $reservation{$event_id} }), \&_report_err) if exists $reservation{$event_id};
        }
        {
            my $i = 0;
            for my $user_id (keys %user_reservations) {
                $self->redis->zadd("recent_reservations:$user_id", @{ $user_reservations{$user_id} }, \&_report_err);
                $self->redis->wait_all_responses() if $i++ % 1000 == 999;
            }
            $self->redis->wait_all_responses()
        };
        {
            my @user_ids = keys %user_total_price;
            while (my @targets = splice @user_ids, 0, 1000) {
                $self->redis->mset((map { ("total_price:$_", $user_total_price{$_}) } @targets), \&_report_err);
            }
        };
        $self->redis->wait_all_responses();

        {
            my $i = 0;
            my $recent_events = $self->dbh->select_all('SELECT id, user_id, event_id, updated_at FROM (SELECT user_id, event_id, id, updated_at, ROW_NUMBER() OVER (PARTITION BY user_id, event_id ORDER BY updated_at DESC) AS `rank` FROM reservations) a WHERE a.rank = 1 GROUP BY user_id, event_id');
            for my $re (@$recent_events) {
                $self->redis->zadd("recent_events:$re->{user_id}", $re->{updated_at}.$re->{id}, $re->{event_id}, \&_report_err);
                $self->redis->wait_all_responses() if $i++ % 1000 == 999;
            }
            $self->redis->wait_all_responses();
        };
    };

    return $c->req->new_response(204, [], '');
};

post '/api/users' => [qw/allow_json_request/] => sub {
    my ($self, $c) = @_;
    my $nickname   = $c->req->body_parameters->get('nickname');
    my $login_name = $c->req->body_parameters->get('login_name');
    my $password   = $c->req->body_parameters->get('password');

    my $user_id = $self->redis->incr("last_user_id");
    my $pass_hash = sha256_hex($password);

    my $ok = $self->redis->hsetnx("userauth:$login_name", $pass_hash, $user_id);
    return $self->res_error($c, duplicated => 409) unless $ok;

    $self->redis->mset(
        "total_price:$user_id" => 0,
        "nickname:$user_id"    => encode_utf8($nickname),
    );

    my $res = $c->render_json({ id => 0+$user_id, nickname => $nickname });
    $res->status(201);
    return $res;
};

sub get_user {
    my ($self, $user_id) = @_;

    state %hard_cache;
    return {%{ $hard_cache{$user_id} }} if $user_id <= 5000 && exists $hard_cache{$user_id};

    my $nickname = $self->redis->get("nickname:$user_id");
    return unless $nickname;

    my %user = (
        id       => 0+$user_id,
        nickname => decode_utf8($nickname),
    );
    if ($user_id <= 5000) {
        $hard_cache{$user_id} = { %user };
    }
    return \%user;
}

sub get_user_with_details {
    my ($self, $user_id) = @_;
    my $user = $self->get_user($user_id);

    my $sheet_map = $self->sheets_map();

    my %event_map;
    my @recent_reservations;
    {
        my $reservation_log_ids = $self->redis->zrevrange("recent_reservations:$user_id", 0, 4);
        last unless @$reservation_log_ids;

        my $rows = $self->dbh->select_all('SELECT * FROM reservations WHERE id IN (?)', $reservation_log_ids);
        my @events = $self->get_events_by_ids([uniq map { $_->{event_id} } @$rows]);
        for my $event (@events) {
            my $event_id = $event->{id};
            $event_map{$event_id} = $event;
        }

        my %map = map { $_->{id} => $_ } @$rows;
        for my $log_id (@$reservation_log_ids) {
            my $row = $map{$log_id};
            my $event = $event_map{$row->{event_id}};
            my $sheet = $sheet_map->{$row->{sheet_id}};
            my $reservation = {
                id          => 0+$row->{id},
                event       => $event,
                sheet_rank  => $sheet->{rank},
                sheet_num   => 0+$sheet->{num},
                price       => $event->{sheets}->{$sheet->{rank}}->{price},
                reserved_at => $row->{reserved_at},
                canceled_at => $row->{canceled_at},
            };
            push @recent_reservations => $reservation;
        }
    };
    $user->{recent_reservations} = \@recent_reservations;
    $user->{total_price} = 0+$self->redis->get("total_price:$user_id");

    my @recent_events;
    {
        my $event_ids = $self->redis->zrevrange("recent_events:$user_id", 0, 4);
        if (my @unfetched_event_ids = grep { !$event_map{$_} } @$event_ids) {
            my @events = $self->get_events_by_ids(\@unfetched_event_ids);
            for my $event (@events) {
                my $event_id = $event->{id};
                $event_map{$event_id} = $event;
            }
        }

        @recent_events = @event_map{@$event_ids};
    }
    $user->{recent_events} = \@recent_events;

    return $user;
}

sub get_login_user {
    my ($self, $c) = @_;

    my $user_id = $self->get_login_user_id($c);
    return unless $user_id;
    return $self->get_user($user_id);
}

sub get_login_user_id {
    my ($self, $c) = @_;
    return $c->env->{'psgix.session'}->{user_id};
}

get '/api/users/{id}' => [qw/login_required/] => sub {
    my ($self, $c) = @_;
    if ($c->args->{id} != $self->get_login_user_id($c)) {
        return $self->res_error($c, forbidden => 403);
    }

    my $user = $self->get_user_with_details($c->args->{id});
    return $c->render_json($user);
};

post '/api/actions/login' => [qw/allow_json_request/] => sub {
    my ($self, $c) = @_;
    my $login_name = $c->req->body_parameters->get('login_name');
    my $password   = $c->req->body_parameters->get('password');

    my $pass_hash = sha256_hex($password);

    my $user_id = $self->redis->hget("userauth:$login_name", $pass_hash);
    return $self->res_error($c, authentication_failed => 401) unless $user_id;

    my $session = Plack::Session->new($c->env);
    $session->set('user_id' => $user_id);

    my $user = $self->get_user($user_id);
    my $res = $c->render_json($user);
    $res->cookies->{user_id} = {
        value => $user_id,
        path  => "/",
    };
    return $res;
};

post '/api/actions/logout' => [qw/login_required/] => sub {
    my ($self, $c) = @_;
    my $session = Plack::Session->new($c->env);
    $session->remove('user_id');
    my $res = $c->req->new_response(204, [], '');
    $res->cookies->{user_id} = {
        value   => '',
        path    => "/",
        expires => 0,
    };
    return $res;
};

get '/api/events' => sub {
    my ($self, $c) = @_;
    my @events = map { $self->sanitize_event($_) } $self->get_events();
    return $c->render_json(\@events);
};

get '/api/events/{id}' => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};

    my $user_id = $self->get_login_user_id($c);
    my $event = $self->get_event_with_detail($event_id, $user_id);
    return $self->res_error($c, not_found => 404) if !$event || !$event->{public};

    $event = $self->sanitize_event($event);
    return $c->render_json($event);
};

sub get_events {
    my ($self, $where) = @_;
    $where ||= sub { $_->{public_fg} };

    my $event_ids = $self->redis->zrange('public_events', 0, -1);
    my @events = $self->get_events_by_ids($event_ids);
    return @events;
}

sub get_raw_event {
    my ($self, $event_id) = @_;

    my $event = $self->redis->get("event_base:$event_id");
    return unless $event;
    return _decode_json_utf8($event);
}

sub get_raw_events {
    my ($self, $event_ids) = @_;
    return map { defined $_ ? _decode_json_utf8($_) : () } $self->redis->mget(map { "event_base:$_" } @$event_ids);
}

sub get_event_with_detail {
    my ($self, $event_id, $login_user_id) = @_;
    my $event = $self->get_raw_event($event_id);
    return unless $event;

    my @sheets = $self->sorted_sheets();

    my %detail_map;
    $self->redis->hgetall("reservation:$event_id", sub {
        my ($ret, $error) = @_;
        die $error if defined $error;

        my %reservation_map = @$ret;
        for my $sheet_id (keys %reservation_map) {
            my $reservation = _decode_json_utf8($reservation_map{$sheet_id});

            $detail_map{$sheet_id} = {
                num         => 0+$reservation->{num},
                reserved    => JSON::XS::true,
                reserved_at => 0+$reservation->{reserved_at},
                ($login_user_id && $reservation->{user_id} == $login_user_id) ? (
                    mine => JSON::XS::true,
                ) : (),
            };
        }
    });
    $self->redis->wait_all_responses();

    for my $sheet (@sheets) {
        my $rank = $sheet->{rank};

        my $detail;
        if (exists $detail_map{$sheet->{id}}) {
            $detail = $detail_map{$sheet->{id}};
            $event->{remains}--;
            $event->{sheets}->{$rank}->{remains}--;
        } else {
            $detail = { num => 0+$sheet->{num} };
        }

        push @{ $event->{sheets}->{$rank}->{detail} } => $detail;
    }

    return $event;
}

sub get_events_by_ids {
    my ($self, $event_ids) = @_;

    my @events = $self->get_raw_events($event_ids);
    return unless @events;

    for my $event (@events) {
        my $event_id = $event->{id};
        $self->redis->hmget("reserved_count:$event_id", RANKS, sub {
            my ($ret, $error) = @_;
            die $error if defined $error;

            my ($s_reserved, $a_reserved, $b_reserved, $c_reserved) = @$ret;
            $event->{remains} -= $s_reserved + $a_reserved + $b_reserved + $c_reserved;
            $event->{sheets}->{S}->{remains} -= $s_reserved;
            $event->{sheets}->{A}->{remains} -= $a_reserved;
            $event->{sheets}->{B}->{remains} -= $b_reserved;
            $event->{sheets}->{C}->{remains} -= $c_reserved;
        });
    }
    $self->redis->wait_all_responses();

    return @events;
}

sub _clone_sv { $_[0] } # clone sv object to avoid to change SV typed slots

sub sanitize_event {
    my ($self, $event) = @_;
    my $sanitized = {%$event}; # shallow clone
    delete $sanitized->{price};
    delete $sanitized->{public};
    delete $sanitized->{closed};
    return $sanitized;
}

post '/api/events/{id}/actions/reserve' => [qw/allow_json_request login_required/] => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};

    my $rank = $c->req->body_parameters->get('sheet_rank');
    return $self->res_error($c, invalid_rank => 400)  unless $self->validate_rank($rank);

    my $user_id = $self->get_login_user_id($c);
    my $event   = $self->get_raw_event($event_id);
    return $self->res_error($c, invalid_event => 404) unless $event && $event->{public};

    my ($sheet_num, $reservation_id);
    until ($reservation_id) {
        $sheet_num = $self->redis->lpop("free_sheets:$event_id:$rank");
        unless ($sheet_num) {
            my $res = $c->render_json({
                error => 'sold_out',
            });
            $res->status(409);
            return $res;
        }

        my $sheet = $self->get_sheet($rank, $sheet_num);

        eval {
            my $now = time;

            $reservation_id = $self->redis->incr('last_rid');

            $self->redis->hincrby("reserved_count:$event_id", $rank, 1, \&_report_err);
            $self->redis->hset("reservation:$event_id", $sheet->{id}, _encode_json_utf8({ num => 0+$sheet_num, user_id => 0+$user_id, reserved_at => 0+$now, log_id => $reservation_id }), \&_report_err);
            $self->redis->incrby("total_price:$user_id", $event->{sheets}->{$rank}->{price}, \&_report_err);
            $self->redis->zadd("recent_events:$user_id", $now.$reservation_id, $event->{id}, \&_report_err);
            $self->redis->zadd("recent_reservations:$user_id", $now.$reservation_id, $reservation_id, \&_report_err);

            $self->dbh->query('INSERT INTO reservations (id, event_id, sheet_id, user_id, reserved_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)', $reservation_id, $event->{id}, $sheet->{id}, $user_id, $now, $now);
            $self->redis->wait_all_responses();
        };
        if ($@) {
            warn $@;
            $self->redis->rpush("free_sheets:$event_id:$rank", $sheet_num);
            return $self->res_error($c);
        }
    }

    my $res = $c->render_json({
        id         => 0+$reservation_id,
        sheet_rank => $rank,
        sheet_num  => 0+$sheet_num,
    });
    $res->status(202);
    return $res;
};

router ['DELETE'] => '/api/events/{id}/sheets/{rank}/{num}/reservation' => [qw/login_required/] => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};
    my $rank     = $c->args->{rank};
    my $num      = $c->args->{num};

    my $user_id = $self->get_login_user_id($c);

    my $event   = $self->get_raw_event($event_id);
    return $self->res_error($c, invalid_event => 404) unless $event && $event->{public};
    return $self->res_error($c, invalid_rank => 404)  unless $self->validate_rank($rank);

    my $sheet = $self->get_sheet($rank, $num);
    return $self->res_error($c, invalid_sheet => 404) unless $sheet;

    my $reservation = $self->redis->hget("reservation:$event_id", $sheet->{id});
    return $self->res_error($c, not_reserved => 400) unless $reservation;

    $reservation = _decode_json_utf8($reservation);
    return $self->res_error($c, not_permitted => 403) unless $reservation->{user_id} == $user_id;

    my $now = time;
    $self->redis->rpush("free_sheets:$event_id:$rank", $sheet->{num}, \&_report_err);
    $self->redis->hincrby("reserved_count:$event_id", $rank, -1, \&_report_err);
    $self->redis->hdel("reservation:$event_id", $sheet->{id}, \&_report_err);
    $self->redis->decrby("total_price:$user_id", $event->{sheets}->{$rank}->{price}, \&_report_err);
    $self->redis->zadd("recent_events:$user_id", $now.$reservation->{log_id}, $event->{id}, \&_report_err);
    $self->redis->zadd("recent_reservations:$user_id", $now.$reservation->{log_id}, $reservation->{log_id}, \&_report_err);
    $self->redis->wait_all_responses();

    $self->dbh->query('UPDATE reservations SET canceled_at = ?, updated_at = ? WHERE id = ?', $now, $now, $reservation->{log_id});

    return $c->req->new_response(204, [], '');
};

sub validate_rank {
    my ($self, $rank) = @_;
    return unless $rank;
    return $rank eq 'S' || $rank eq 'A' || $rank eq 'B' || $rank eq 'C';
}

sub sheets_map {
    my $self = shift;

    state $cache;
    return $cache ||= $self->dbh->selectall_hashref('SELECT * FROM sheets', 'id');
}

sub sorted_sheets {
    my $self = shift;

    state $cache;
    return @$cache if $cache;

    my @sheets = map $_->[1], sort { $a->[0] <=> $b->[0] } map [$_->{id}, $_], values %{ $self->sheets_map() };
    $cache = \@sheets;
    return @sheets;
}

sub get_sheets_by_rank {
    my ($self, $rank) = @_;

    state %cache;
    return @{ $cache{$rank} } if exists $cache{$rank};

    for my $sheet (values %{ $self->sheets_map }) {
        push @{ $cache{$sheet->{rank}} } => $sheet;
    }
    return @{ $cache{$rank} };
}

sub get_sheet {
    my ($self, $rank, $num) = @_;

    state %cache;
    return $cache{$rank}{$num} if exists $cache{$rank}{$num};

    for my $sheet (values %{ $self->sheets_map }) {
        $cache{$sheet->{rank}}{$sheet->{num}} = $sheet;
    }
    return $cache{$rank}{$num};
}

filter admin_login_required => sub {
    my $app = shift;
    return sub {
        my ($self, $c) = @_;
        my $session = Plack::Session->new($c->env);

        my $administrator_id = $self->get_login_administrator_id($c);
        return $self->res_error($c, admin_login_required => 401) unless $administrator_id;

        $app->($self, $c);
    };
};

filter fillin_administrator => sub {
    my $app = shift;
    return sub {
        my ($self, $c) = @_;

        my $administrator = $self->get_login_administrator($c);
        $c->stash->{administrator} = $administrator if $administrator;

        $app->($self, $c);
    };
};

get '/admin/' => [qw/fillin_administrator/] => sub {
    my ($self, $c) = @_;

    my @events;
    if ($c->stash->{administrator}) {
        my $event_ids = $self->redis->zrange('all_events', 0, -1);
        @events = $self->get_events_by_ids($event_ids);
    }

    return $c->render('admin.tx', {
        events      => \@events,
        encode_json => \&_encode_json_for_html,
    });
};

post '/admin/api/actions/login' => [qw/allow_json_request/] => sub {
    my ($self, $c) = @_;
    my $login_name = $c->req->body_parameters->get('login_name');
    my $password   = $c->req->body_parameters->get('password');

    my $administrator = $self->dbh->select_row('SELECT id, nickname FROM administrators WHERE login_name = ? AND pass_hash = ?', $login_name, sha256_hex($password));
    return $self->res_error($c, authentication_failed => 401) unless $administrator;

    my $session = Plack::Session->new($c->env);
    $session->set('administrator_id' => $administrator->{id});
    my $res = $c->render_json($administrator);
    $res->cookies->{admin} = {
        value => 1,
        path  => "/admin/",
    };
    return $res;
};

post '/admin/api/actions/logout' => [qw/admin_login_required/] => sub {
    my ($self, $c) = @_;
    my $session = Plack::Session->new($c->env);
    $session->remove('administrator_id');
    my $res = $c->req->new_response(204, [], '');
    $res->cookies->{admin} = {
        value => '',
        path  => "/admin/",
        expires => 0,
    };
    return $res;
};

sub get_login_administrator {
    my ($self, $c) = @_;
    my $administrator_id = $self->get_login_administrator_id($c);
    return unless $administrator_id;
    return $self->dbh->select_row('SELECT id, nickname FROM administrators WHERE id = ?', $administrator_id);
}

sub get_login_administrator_id {
    my ($self, $c) = @_;
    return $c->env->{'psgix.session'}->{administrator_id};
}

get '/admin/api/events' => [qw/admin_login_required/] => sub {
    my ($self, $c) = @_;

    my $event_ids = $self->redis->zrange('all_events', 0, -1);
    my @events = $self->get_events_by_ids($event_ids);

    return $c->render_json(\@events);
};

post '/admin/api/events' => [qw/allow_json_request admin_login_required/] => sub {
    my ($self, $c) = @_;
    my $title  = $c->req->body_parameters->get('title');
    my $public = $c->req->body_parameters->get('public') ? 1 : 0;
    my $price  = $c->req->body_parameters->get('price');

    my $event_id = $self->redis->incr("last_event_id");

    my $event = {
        id      => 0+$event_id,
        title   => $title,
        public  => $public ? JSON::XS::true : JSON::XS::false,
        closed  => JSON::XS::false,
        price   => 0+$price,
        total   => 1000,
        remains => 1000,
        sheets  => {
            map {
                $_ => {
                    total   => $SHEETS_MAP{$_},
                    remains => $SHEETS_MAP{$_},
                    price   => $price+$PRICE_MAP{$_},
                },
            } RANKS
        },
    };
    $self->create_initial_event_states([$event]);

    return $c->render_json($event);
};

sub create_initial_event_states {
    my ($self, $events) = @_;

    for my $event (@$events) {
        my $event_id = $event->{id};

        $self->redis->zadd("all_events", $event_id, $event_id, \&_report_err);
        $self->redis->set("event_base:$event_id", _encode_json_utf8($event), \&_report_err);
        for my $rank (RANKS) {
            my @sheets = shuffle 1..$SHEETS_MAP{$rank};
            $self->redis->lpush("free_sheets:$event_id:$rank", @sheets, \&_report_err);
            $self->redis->hset("reserved_count:$event_id", $rank, 0, \&_report_err);
        }
        $self->redis->zadd("public_events", $event_id, $event_id, \&_report_err) if $event->{public};
    }
    $self->redis->wait_all_responses();
}

get '/admin/api/events/{id}' => [qw/admin_login_required/] => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};

    my $event = $self->get_event_with_detail($event_id);
    return $self->res_error($c, not_found => 404) unless $event;

    return $c->render_json($event);
};

post '/admin/api/events/{id}/actions/edit' => [qw/allow_json_request admin_login_required/] => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};
    my $public = $c->req->body_parameters->get('public') ? 1 : 0;
    my $closed = $c->req->body_parameters->get('closed') ? 1 : 0;
    $public = 0 if $closed;

    my $event = $self->get_raw_event($event_id);
    return $self->res_error($c, not_found => 404) unless $event;

    if ($event->{closed}) {
        return $self->res_error($c, cannot_edit_closed_event => 400);
    } elsif ($event->{public} && $closed) {
        return $self->res_error($c, cannot_close_public_event => 400);
    }

    $event->{public} = $public ? JSON::XS::true : JSON::XS::false;
    $event->{closed} = $closed ? JSON::XS::true : JSON::XS::false;

    $self->redis->zadd("all_events", $event_id, $event_id, \&_report_err);
    $self->redis->set("event_base:$event_id", _encode_json_utf8($event), \&_report_err);
    if ($public) {
        $self->redis->zadd("public_events", $event_id, $event_id, \&_report_err);
    } else {
        $self->redis->zrem("public_events", $event_id, \&_report_err);
    }
    $self->redis->wait_all_responses();

    return $c->render_json($event);
};

get '/admin/api/reports/events/{id}/sales' => [qw/admin_login_required/] => sub {
    my ($self, $c) = @_;
    my $event_id = $c->args->{id};
    return $self->render_report_csv('SELECT * FROM reservations WHERE event_id = ? ORDER BY id ASC', $event_id);
};

get '/admin/api/reports/sales' => [qw/admin_login_required/] => sub {
    my ($self, $c) = @_;
    return $self->render_report_csv('SELECT * FROM reservations ORDER BY id ASC');
};

sub render_report_csv {
    my ($self, $query, @bind) = @_;

    my $event_ids = $self->redis->zrange('all_events', 0, -1);
    my %event_map = map { $_->{id} => $_ } $self->get_raw_events($event_ids);
    my %sheets_map = %{ $self->sheets_map };

    my ($event_id, $cache_fh);
    if (@bind) {
        $event_id = $bind[0];
        my $closed = $event_map{$event_id}{closed};
        if ($closed) {
            if (-f "/tmp/report_$event_id.csv") {
                open $cache_fh, '<', "/tmp/report_$event_id.csv"
                    or die $!;

                return Kossy::Response->new(200, [
                    'Content-Type'        => 'text/csv; charset=UTF-8',
                    'Content-Disposition' => 'attachment; filename="report.csv"',
                ], $cache_fh);
            }

            open $cache_fh, '>', "/tmp/report_$event_id.csv.tmp"
                or die $!;
        }
    }

    return Kossy::Response->new_with_code(sub {
        my $respond = shift;
        my $writer = $respond->([
            200, [
                'Content-Type'        => 'text/csv; charset=UTF-8',
                'Content-Disposition' => 'attachment; filename="report.csv"',
            ]
        ]);

        if ($cache_fh) {
            my $super = $writer;
            $writer = Plack::Util::inline_object(
                write => sub {
                    print {$cache_fh} @_;
                    $super->write(@_);
                },
                close => sub {
                    close $cache_fh or die $!;
                    rename "/tmp/report_$event_id.csv.tmp", "/tmp/report_$event_id.csv";
                    $super->close(@_);
                },
            );
        }

        my @keys = qw/reservation_id event_id rank num price user_id sold_at canceled_at/;
        if (@bind) {
            $writer->write(join ',', @keys);
            $writer->write("\n");
        } else {
            my ($file) = glob "/tmp/report_all_prefix_*.csv";
            my ($rid) = $file =~ m!^/tmp/report_all_prefix_([0-9]+).csv$!;

            my $buf = "\0" x 8192;
            open my $fh, '<', $file;
            until (eof $fh) {
                read $fh, $buf, 8192;
                $writer->write($buf);
            }

            $query = 'SELECT * FROM reservations WHERE id >= ? ORDER BY id ASC';
            @bind = ($rid);
        }

        my $dbh = $self->dbh->clone({ mysql_use_result => 1 });
        my $sth = $dbh->prepare($query);
        $sth->execute(@bind);

        my %reservation;
        $sth->bind_columns(\(@reservation{qw/id event_id sheet_id user_id reserved_at canceled_at updated_at/}));
        while ($sth->fetch) {
            my $event = ($event_map{$reservation{event_id}} ||= $self->get_raw_event($reservation{event_id}));
            my $sheet = $sheets_map{$reservation{sheet_id}};

            my %report = (
                reservation_id => $reservation{id},
                event_id       => $reservation{event_id},
                rank           => $sheet->{rank},
                num            => $sheet->{num},
                user_id        => $reservation{user_id},
                sold_at        => Time::Moment->from_epoch($reservation{reserved_at}, 0)->to_string(),
                canceled_at    => $reservation{canceled_at} ? Time::Moment->from_epoch($reservation{canceled_at}, 0)->to_string() : '',
                price          => $event->{price} + $sheet->{price},
            );

            $writer->write(join ',', @report{@keys});
            $writer->write("\n");
        }

        $writer->close();

        $sth->finish();
        $dbh->disconnect();
    });
}

sub res_error {
    my ($self, $c, $error, $status) = @_;
    $error  ||= 'unknown';
    $status ||= 500;

    my $res = $c->render_json({ error => $error });
    $res->status($status);
    return $res;
}

package Kossy::Response {
    use Scalar::Util qw/reftype/;

    sub new_with_code {
        my ($class, $code) = @_;
        bless \$code, $class;
    }

    BEGIN {
        my $super = \&finalize;
        no warnings qw/redefine/;
        *finalize = sub {
            my $self = shift;
            if (reftype $self eq 'REF') {
                return $$self;
            }

            $self->$super(@_);
        };
    };
};

1;
