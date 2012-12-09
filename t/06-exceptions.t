use 5.006000;
use strict;
use warnings;

use lib 't/tlib';
use Test::More tests => 13;
use Test::AnyEvent::RedisHandle;
use AnyEvent;
use AnyEvent::Redis::RipeRedis;

my $T_CLASS = 'AnyEvent::Redis::RipeRedis';

t_conn_timeout();
t_response_timeout();
t_encoding();
t_on_connect();
t_on_disconnect();
t_on_error();
t_on_done();
t_cmd_on_error();
t_on_message();


# Subroutines

####
sub t_conn_timeout {
  my $t_except;

  eval {
    my $redis = $T_CLASS->new(
      connection_timeout => 'invalid_timeout',
    );
  };
  if ( $@ ) {
    chomp( $@ );
    $t_except = $@;
  }
  ok( $t_except =~ m/^Connection timeout must be a positive number/o,
      'Invalid connection timeout (character string)' );

  undef( $t_except );
  eval {
    my $redis = $T_CLASS->new(
      connection_timeout => -5,
    );
  };
  if ( $@ ) {
    chomp( $@ );
    $t_except = $@;
  }
  ok( $t_except =~ m/^Connection timeout must be a positive number/o,
      'Invalid connection timeout (negative number)' );

  return;
}

####
sub t_response_timeout {
  my $t_except;

  eval {
    my $redis = $T_CLASS->new(
      response_timeout => 'invalid_timeout',
    );
  };
  if ( $@ ) {
    chomp( $@ );
    $t_except = $@;
  }
  ok( $t_except =~ m/^Response timeout must be a positive number/o,
      'Invalid response timeout (character string)' );

  undef( $t_except );
  eval {
    my $redis = $T_CLASS->new(
      response_timeout => -5,
    );
  };
  if ( $@ ) {
    chomp( $@ );
    $t_except = $@;
  }
  ok( $t_except =~ m/^Response timeout must be a positive number/o,
      'Invalid response timeout (negative number)' );

  return;
}

####
sub t_encoding {
  eval {
    my $redis = $T_CLASS->new(
      encoding => 'invalid_enc',
    );
  };
  my $t_except;
  if ( $@ ) {
    chomp( $@ );
    $t_except = $@;
  }

  ok( $t_except =~ m/^Encoding 'invalid_enc' not found/o,
      'Invalid encoding' );

  return;
}

# Invalid "on_connect"
####
sub t_on_connect {
  eval {
    my $redis = $T_CLASS->new(
      on_connect => 'invalid',
    );
  };
  my $t_except;
  if ( $@ ) {
    chomp( $@ );
    $t_except = $@;
  }

  ok( $t_except =~ m/^'on_connect' callback must be a code reference/o,
      "Invalid 'on_connect' callback" );

  return;
}

####
sub t_on_disconnect {
  eval {
    my $redis = $T_CLASS->new(
      on_disconnect => {},
    );
  };
  my $t_except;
  if ( $@ ) {
    chomp( $@ );
    $t_except = $@;
  }

  ok( $t_except =~ m/^'on_disconnect' callback must be a code reference/o,
      "Invalid 'on_disconnect' callback" );

  return;
}

####
sub t_on_error {
  eval {
    my $redis = $T_CLASS->new(
      on_error => [],
    );
  };
  my $t_except;
  if ( $@ ) {
    chomp( $@ );
    $t_except = $@;
  }

  ok( $t_except =~ m/^'on_error' callback must be a code reference/o,
      "Invalid 'on_error' callback in the constructor" );

  return;
}

####
sub t_on_done {
  my $redis = $T_CLASS->new();

  eval {
    $redis->incr( 'foo', {
      on_done => 'invalid',
    } );
  };
  my $t_except;
  if ( $@ ) {
    chomp( $@ );
    $t_except = $@;
  }

  ok( $t_except =~ m/^'on_done' callback must be a code reference/o,
      "Invalid 'on_done' callback" );

  return;
}

# Invalid "on_error"
sub t_cmd_on_error {
  my $redis = $T_CLASS->new();

  eval {
    $redis->incr( 'foo', {
      on_error => [],
    } );
  };
  my $t_except;
  if ( $@ ) {
    chomp( $@ );
    $t_except = $@;
  }

  ok( $t_except =~ m/^'on_error' callback must be a code reference/o,
      "Invalid 'on_error' callback in the method of the command" );

  return;
}

####
sub t_on_message {
  my $redis = $T_CLASS->new();

  my $t_except;

  eval {
    $redis->subscribe( 'channel' );
  };
  if ( $@ ) {
    chomp( $@ );
    $t_except = $@;
  }
  ok( $t_except =~ m/^'on_message' callback must be specified/o,
      "'on_message' callback not specified" );

  eval {
    $redis->subscribe( 'channel', {
      on_message => 'invalid',
    } );
  };
  if ( $@ ) {
    chomp( $@ );
    $t_except = $@;
  }
  ok( $t_except =~ m/^'on_message' callback must be a code reference/o,
      "Invalid 'on_message' callback (scalar)" );

  eval {
    $redis->subscribe( 'channel', {
      on_message => {},
    } );
  };
  if ( $@ ) {
    chomp( $@ );
    $t_except = $@;
  }
  ok( $t_except =~ m/^'on_message' callback must be a code reference/o,
      "Invalid 'on_message' callback (hash reference)" );

  return;
}