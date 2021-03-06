use 5.008000;
use strict;
use warnings;
use utf8;

use Test::More;
use AnyEvent::Redis::RipeRedis qw( :err_codes );
require 't/test_helper.pl';

my $server_info = run_redis_instance();
if ( !defined( $server_info ) ) {
  plan skip_all => 'redis-server is required for this test';
}
plan tests => 22;

my $redis;
my $t_is_conn = 0;
my $t_is_disconn = 0;

ev_loop(
  sub {
    my $cv = shift;

    $redis = AnyEvent::Redis::RipeRedis->new(
      host => $server_info->{host},
      port => $server_info->{port},
      connection_timeout => 5,
      read_timeout => 5,
      encoding => 'utf8',
      on_connect => sub {
        $t_is_conn = 1;
        $cv->send();
      },
      on_disconnect => sub {
        $t_is_disconn = 1;
      },
    );
  },
);

ok( $t_is_conn, 'connected' );

t_ping( $redis );
t_incr( $redis );
t_set_get( $redis );
t_set_get_undef( $redis );
t_set_get_utf8( $redis );
t_get_non_existent( $redis );
t_lrange( $redis );
t_get_empty_list( $redis );
t_mbulk_undef( $redis );
t_transaction( $redis );
t_command_error( $redis );
t_default_on_error( $redis );
t_error_after_exec( $redis );
t_quit( $redis );


####
sub t_ping {
  my $redis = shift;

  my $t_data;

  ev_loop(
    sub {
      my $cv = shift;

      $redis->ping( {
        on_done => sub {
          $t_data = shift;
          $cv->send();
        },
      } );
    }
  );

  is( $t_data, 'PONG', 'PING; status reply' );

  return;
}

####
sub t_incr {
  my $redis = shift;

  my $t_data;

  ev_loop(
    sub {
      my $cv = shift;

      $redis->incr( 'foo', {
        on_done => sub {
          $t_data = shift;
          $cv->send();
        },
      } );
    }
  );

  is( $t_data, 1, 'INCR; numeric reply' );

  return;
}

####
sub t_set_get {
  my $redis = shift;

  my $t_data;

  ev_loop(
    sub {
      my $cv = shift;

      $redis->set( 'bar', "some\r\nstring" );
      $redis->get( 'bar', {
        on_done => sub {
          $t_data = shift;
          $cv->send();
        },
      } );
    }
  );

  is( $t_data, "some\r\nstring", 'GET; bulk reply' );

  return;
}

####
sub t_set_get_undef {
  my $redis = shift;

  my $t_data;

  ev_loop(
    sub {
      my $cv = shift;

      $redis->set( 'empty', undef );
      $redis->get( 'empty', {
        on_done => sub {
          $t_data = shift;
          $cv->send();
        },
      } );
    }
  );

  is( $t_data, '', 'SET/GET undef' );

  return;
}

####
sub t_set_get_utf8 {
  my $redis = shift;

  my $t_data;

  ev_loop(
    sub {
      my $cv = shift;

      $redis->set( 'ключ', 'Значение' );
      $redis->get( 'ключ', {
        on_done => sub {
          $t_data = shift;
          $cv->send();
        },
      } );
    }
  );

  is( $t_data, 'Значение', 'SET/GET UTF-8 string' );

  return;
}

####
sub t_get_non_existent {
  my $redis = shift;

  my $t_data = 'not_ubdef';

  ev_loop(
    sub {
      my $cv = shift;

      $redis->get( 'non_existent', {
        on_done => sub {
          $t_data = shift;
          $cv->send();
        },
      } );
    }
  );

  is( $t_data, undef, 'GET non existent key' );

  return;
}

####
sub t_lrange {
  my $redis = shift;

  my $t_data;

  ev_loop(
    sub {
      my $cv = shift;

      for ( my $i = 2; $i <= 3; $i++ ) {
        $redis->rpush( 'list', "element_$i" );
      }
      $redis->lpush( 'list', 'element_1' );
      $redis->lrange( 'list', 0, -1, {
        on_done => sub {
          $t_data = shift;
          $cv->send();
        },
      } );
    }
  );

  is_deeply( $t_data, [ qw(
    element_1
    element_2
    element_3
  ) ], 'LRANGE; multi-bulk reply' );

  return;
}

####
sub t_get_empty_list {
  my $redis = shift;

  my $t_data;

  ev_loop(
    sub {
      my $cv = shift;

      $redis->lrange( 'non_existent', 0, -1, {
        on_done => sub {
          $t_data = shift;
          $cv->send();
        }
      } );
    },
  );

  is_deeply( $t_data, [], 'LRANGE; empty list' );

  return;
}

####
sub t_mbulk_undef {
  my $redis = shift;

  my $t_data = 'not_undef';

  ev_loop(
    sub {
      my $cv = shift;

      $redis->brpop( 'non_existent', '1', {
        on_done => sub {
          $t_data = shift;
          $cv->send();
        },
      } );
    }
  );

  is( $t_data, undef, 'BRPOP; multi-bulk undef' );

  return;
}

####
sub t_transaction {
  my $redis = shift;

  my $t_data;

  ev_loop(
    sub {
      my $cv = shift;

      $redis->multi();
      $redis->incr( 'foo' );
      $redis->lrange( 'list', 0, -1 );
      $redis->lrange( 'non_existent', 0, -1 );
      $redis->get( 'bar' );
      $redis->lrange( 'list', 0, -1 );
      $redis->exec( {
        on_done => sub {
          $t_data = shift;
          $cv->send();
        },
      } );
    }
  );

  is_deeply( $t_data, [
    2,
    [ qw(
      element_1
      element_2
      element_3
    ) ],
    [],
    "some\r\nstring",
    [ qw(
      element_1
      element_2
      element_3
    ) ],
  ], 'EXEC; nested multi-bulk reply' );

  return;
}

####
sub t_command_error {
  my $redis = shift;

  my $t_err_msg;
  my $t_err_code;

  ev_loop(
    sub {
      my $cv = shift;

      $redis->set( {
        on_error => sub {
          $t_err_msg = shift;
          $t_err_code = shift;
          $cv->send();
        }
      } );
    }
  );

  my $t_name = 'command error';
  like( $t_err_msg, qr/^ERR/o, "$t_name; error message" );
  is( $t_err_code, E_OPRN_ERROR, "$t_name; error code" );

  return;
}

####
sub t_default_on_error {
  my $redis = shift;

  local %SIG;

  my $t_err_msg;

  ev_loop(
    sub {
      my $cv = shift;

      $SIG{__WARN__} = sub {
        $t_err_msg = shift;
        chomp( $t_err_msg );
        $cv->send();
      };
      $redis->set(); # missing argument
    }
  );

  undef( $SIG{__WARN__} );

  like( $t_err_msg, qr/^ERR/o, "Default 'on_error' callback" );

  return;
}

####
sub t_error_after_exec {
  my $redis = shift;

  my $t_err_msg;
  my $t_err_code;
  my $t_data;

  ev_loop(
    sub {
      my $cv = shift;

      $redis->multi();
      $redis->set( 'foo', 'string' );
      $redis->incr( 'foo' );
      $redis->exec( {
        on_error => sub {
          $t_err_msg = shift;
          $t_err_code = shift;
          $t_data = shift;
          $cv->send();
        },
      } );
    }
  );

  my $t_name = 'error after EXEC';
  my $err_class = 'AnyEvent::Redis::RipeRedis::Error';
  is( $t_err_msg, "Operation 'exec' completed with errors.",
      "$t_name; error message" );
  is( $t_err_code, E_OPRN_ERROR, "$t_name; error code" );
  is( $t_data->[0], 'OK', "$t_name; status reply" );
  isa_ok( $t_data->[1], $err_class, "$t_name;" );
  like( $t_data->[1]->message(), qr/^ERR/o,
      "$t_name; nested error message" );
  is( $t_data->[1]->code(), E_OPRN_ERROR, "$t_name; nested error code" );

  return;
}

####
sub t_quit {
  my $redis = shift;

  my $t_data;

  ev_loop(
    sub {
      my $cv = shift;

      $redis->quit( {
        on_done => sub {
          $t_data = shift;
          $cv->send();
        },
      } );
    }
  );

  is( $t_data, 'OK', 'QUIT; status reply;' );
  ok( $t_is_disconn, 'disconnected' );

  return;
}
