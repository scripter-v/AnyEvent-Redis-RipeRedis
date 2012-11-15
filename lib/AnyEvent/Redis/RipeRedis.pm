package AnyEvent::Redis::RipeRedis;

use 5.006000;
use strict;
use warnings;
use base qw( Exporter );

use fields qw(
  host
  port
  password
  database
  connection_timeout
  reconnect
  encoding
  on_connect
  on_disconnect
  on_connect_error
  on_error

  handle
  connected
  auth_status
  db_select_status
  buffer
  processing_queue
  sub_lock
  subs
);

our $VERSION = '1.200';

use AnyEvent::Handle;
use Encode qw( find_encoding is_utf8 );
use Scalar::Util qw( looks_like_number weaken );
use Digest::SHA1 qw( sha1_hex );
use Carp qw( confess );

BEGIN {
  our @EXPORT_OK = qw( E_CANT_CONN E_LOADING_DATASET E_IO
      E_CONN_CLOSED_BY_REMOTE_HOST E_CONN_CLOSED_BY_CLIENT E_NO_CONN
      E_INVALID_PASS E_OPRN_NOT_PERMITTED E_OPRN_ERROR E_UNEXPECTED_DATA
      E_NO_SCRIPT );

  our %EXPORT_TAGS = (
    err_codes => \@EXPORT_OK,
  );
}

use constant {
  # Default values
  D_HOST => 'localhost',
  D_PORT => 6379,

  # Error codes
  E_CANT_CONN => 1,
  E_LOADING_DATASET => 2,
  E_IO => 3,
  E_CONN_CLOSED_BY_REMOTE_HOST => 4,
  E_CONN_CLOSED_BY_CLIENT => 5,
  E_NO_CONN => 6,
  E_INVALID_PASS => 7,
  E_OPRN_NOT_PERMITTED => 8,
  E_OPRN_ERROR => 9,
  E_UNEXPECTED_DATA => 10,
  E_NO_SCRIPT => 11,

  # Command status
  S_NEED_PERFORM => 1,
  S_IN_PROGRESS => 2,
  S_IS_DONE => 3,

  # String terminator
  EOL => "\r\n",
  EOL_LEN => 2,
};

my %SUB_CMDS = (
  subscribe => 1,
  psubscribe => 1,
);
my %SUB_UNSUB_CMDS = (
  %SUB_CMDS,
  unsubscribe => 1,
  punsubscribe => 1,
);

my %EVAL_CACHE;


# Constructor
sub new {
  my $proto = shift;
  my $params = { @_ };

  $params = $proto->_validate_new_params( $params );

  my __PACKAGE__ $self = fields::new( $proto );

  $self->{host} = $params->{host};
  $self->{port} = $params->{port};
  $self->{password} = $params->{password};
  $self->{database} = $params->{database};
  $self->{connection_timeout} = $params->{connection_timeout};
  $self->{reconnect} = $params->{reconnect};
  $self->{encoding} = $params->{encoding};
  $self->{on_connect} = $params->{on_connect};
  $self->{on_disconnect} = $params->{on_disconnect};
  $self->{on_connect_error} = $params->{on_connect_error};
  $self->{on_error} = $params->{on_error};

  $self->{handle} = undef;
  $self->{connected} = 0;
  $self->{auth_status} = S_NEED_PERFORM;
  $self->{db_select_status} = S_NEED_PERFORM;
  $self->{buffer} = [];
  $self->{processing_queue} = [];
  $self->{sub_lock} = 0;
  $self->{subs} = {};

  if ( !$params->{lazy} ) {
    $self->_connect();
  }

  return $self;
}

####
sub disconnect {
  my __PACKAGE__ $self = shift;

  if ( defined( $self->{handle} ) ) {
    $self->{handle}->destroy();
    undef( $self->{handle} );
  }
  my $was_connected = $self->{connected};
  if ( $was_connected ) {
    $self->{connected} = 0;
    $self->{auth_status} = S_NEED_PERFORM;
    $self->{db_select_status} = S_NEED_PERFORM;
  }
  $self->_abort_all( 'Connection closed by client', E_CONN_CLOSED_BY_CLIENT );
  if ( $was_connected and defined( $self->{on_disconnect} ) ) {
    $self->{on_disconnect}->();
  }

  return;
}

####
sub _validate_new_params {
  my $params = pop;

  if (
    defined( $params->{connection_timeout} )
      and ( !looks_like_number( $params->{connection_timeout} )
        or $params->{connection_timeout} < 0 )
      ) {
    confess 'Connection timeout must be a positive number';
  }
  if ( !exists( $params->{reconnect} ) ) {
    $params->{reconnect} = 1;
  }
  if ( defined( $params->{encoding} ) ) {
    my $enc = $params->{encoding};
    $params->{encoding} = find_encoding( $enc );
    if ( !defined( $params->{encoding} ) ) {
      confess "Encoding '$enc' not found";
    }
  }
  foreach my $name (
    qw( on_connect on_disconnect on_connect_error on_error )
      ) {
    if (
      defined( $params->{$name} )
        and ref( $params->{$name} ) ne 'CODE'
        ) {
      confess "'$name' callback must be a code reference";
    }
  }

  if ( !defined( $params->{host} ) ) {
    $params->{host} = D_HOST;
  }
  if ( !defined( $params->{port} ) ) {
    $params->{port} = D_PORT;
  }
  if ( !defined( $params->{on_error} ) ) {
    $params->{on_error} = sub {
      my $err_msg = shift;
      warn "$err_msg\n";
    };
  }

  return $params;
}

####
sub _connect {
  my __PACKAGE__ $self = shift;

  weaken( $self );

  $self->{handle} = AnyEvent::Handle->new(
    connect => [ $self->{host}, $self->{port} ],
    on_prepare => $self->_on_prepare(),
    on_connect => $self->_on_connect(),
    on_connect_error => $self->_on_conn_error(),
    on_eof => $self->_on_eof(),
    on_error => $self->_on_error(),
    on_read => $self->_on_read(
      sub {
        return $self->_prcoess_response( @_ );
      }
    ),
  );

  return;
}

####
sub _on_prepare {
  my __PACKAGE__ $self = shift;

  weaken( $self );

  return sub {
    if ( defined( $self->{connection_timeout} ) ) {
      return $self->{connection_timeout};
    }

    return;
  };
}

####
sub _on_connect {
  my __PACKAGE__ $self = shift;

  weaken( $self );

  return sub {
    $self->{connected} = 1;
    if ( !defined( $self->{password} ) ) {
      $self->{auth_status} = S_IS_DONE;
    }
    if ( !defined( $self->{database} ) ) {
      $self->{db_select_status} = S_IS_DONE;
    }

    if ( $self->{auth_status} == S_NEED_PERFORM ) {
      $self->_auth();
    }
    elsif ( $self->{db_select_status} == S_NEED_PERFORM ) {
      $self->_select_db();
    }
    else {
      $self->_flush_buffer();
    }
    if ( defined( $self->{on_connect} ) ) {
      $self->{on_connect}->();
    }
  };
}

####
sub _on_conn_error {
  my __PACKAGE__ $self = shift;

  weaken( $self );

  return sub {
    my $err_msg = pop;

    $self->{handle}->destroy();
    undef( $self->{handle} );
    $err_msg = "Can't connect to $self->{host}:$self->{port}: $err_msg";
    $self->_abort_all( $err_msg, E_CANT_CONN );
    if ( defined( $self->{on_connect_error} ) ) {
      $self->{on_connect_error}->( $err_msg );
    }
    else {
      $self->{on_error}->( $err_msg, E_CANT_CONN );
    }
  };
}

####
sub _on_eof {
  my __PACKAGE__ $self = shift;

  weaken( $self );

  return sub {
    $self->_process_error( 'Connection closed by remote host',
        E_CONN_CLOSED_BY_REMOTE_HOST );
  };
}

####
sub _on_error {
  my __PACKAGE__ $self = shift;

  weaken( $self );

  return sub {
    my $err_msg = pop;
    $self->_process_error( $err_msg, E_IO );
  };
}

####
sub _process_error {
  my __PACKAGE__ $self = shift;
  my $err_msg = shift;
  my $err_code = shift;

  $self->{handle}->destroy();
  undef( $self->{handle} );
  $self->{connected} = 0;
  $self->{auth_status} = S_NEED_PERFORM;
  $self->{db_select_status} = S_NEED_PERFORM;
  $self->_abort_all( $err_msg, $err_code );
  $self->{on_error}->( $err_msg, $err_code );
  if ( defined( $self->{on_disconnect} ) ) {
    $self->{on_disconnect}->();
  }

  return;
}

####
sub _on_read {
  my __PACKAGE__ $self = shift;
  my $cb = shift;

  my $bulk_len;

  weaken( $self );

  return sub {
    my $hdl = $self->{handle};
    while ( defined( $hdl->{rbuf} ) ) {
      if ( defined( $bulk_len ) ) {
        my $bulk_eol_len = $bulk_len + EOL_LEN;
        if ( length( $hdl->{rbuf} ) < $bulk_eol_len ) {
          return;
        }
        my $data = substr( $hdl->{rbuf}, 0, $bulk_len, '' );
        substr( $hdl->{rbuf}, 0, EOL_LEN, '' );
        if ( defined( $self->{encoding} ) ) {
          $data = $self->{encoding}->decode( $data );
        }
        undef( $bulk_len );

        return 1 if $cb->( $data );
      }
      else {
        my $eol_pos = index( $hdl->{rbuf}, EOL );
        if ( $eol_pos < 0 ) {
          return;
        }
        my $data = substr( $hdl->{rbuf}, 0, $eol_pos, '' );
        my $type = substr( $data, 0, 1, '' );
        substr( $hdl->{rbuf}, 0, EOL_LEN, '' );

        if ( $type eq '+' or $type eq ':' ) {
          return 1 if $cb->( $data );
        }
        elsif ( $type eq '-' ) {
          return 1 if $cb->( $data, 1 );
        }
        elsif ( $type eq '$' ) {
          if ( $data > 0 ) {
            $bulk_len = $data;
          }
          else {
            return 1 if $cb->();
          }
        }
        elsif ( $type eq '*' ) {
          my $mbulk_len = $data;
          if ( $mbulk_len > 0 ) {
            $self->_unshift_read( $mbulk_len, $cb );
            return 1;
          }
          elsif ( $mbulk_len < 0 ) {
            return 1 if $cb->();
          }
          else {
            return 1 if $cb->( [] );
          }
        }
      }
    }
  };
}

####
sub _unshift_read {
  my __PACKAGE__ $self = shift;
  my $mbulk_len = shift;
  my $cb = shift;

  my $read_cb;
  my $resp_cb;
  my @data_list;
  my @errors;
  my $remaining = $mbulk_len;

  {
    my $self = $self;
    weaken( $self );

    $resp_cb = sub {
      my $data = shift;
      my $is_err = shift;

      if ( $is_err ) {
        push( @errors, $data );
      }
      else {
        push( @data_list, $data );
      }

      $remaining--;
      if (
        ref( $data ) eq 'ARRAY' and @{$data}
          and $remaining > 0
          ) {
        $self->{handle}->unshift_read( $read_cb );
      }
      elsif ( $remaining == 0 ) {
        undef( $read_cb ); # Collect garbage
        if ( @errors ) {
          my $err_msg = join( "\n", @errors );
          $cb->( $err_msg, 1 );
        }
        else {
          $cb->( \@data_list );
        }

        return 1;
      }
    };
  }
  $read_cb = $self->_on_read( $resp_cb );

  $self->{handle}->unshift_read( $read_cb );

  return;
}

####
sub _prcoess_response {
  my __PACKAGE__ $self = shift;
  my $data = shift;
  my $is_err = shift;

  if ( $is_err ) {
    $self->_process_cmd_error( $data );
  }
  elsif ( %{$self->{subs}} and $self->_is_pub_message( $data ) ) {
    $self->_process_pub_message( $data );
  }
  else {
    $self->_process_data( $data );
  }

  return;
}

####
sub _process_data {
  my __PACKAGE__ $self = shift;
  my $data = shift;

  my $cmd = $self->{processing_queue}[0];
  if ( defined( $cmd ) ) {
    if ( exists( $SUB_UNSUB_CMDS{$cmd->{name}} ) ) {
      $self->_process_sub_action( $cmd, $data );
      return;
    }
    shift( @{$self->{processing_queue}} );
    if ( $cmd->{name} eq 'quit' ) {
      $self->disconnect();
    }
    if ( defined( $cmd->{on_done} ) ) {
      $cmd->{on_done}->( $data );
    }
  }
  else {
    $self->{on_error}->( "Don't known how process response data."
        . ' Command queue is empty', E_UNEXPECTED_DATA );
  }

  return;
}

####
sub _process_pub_message {
  my __PACKAGE__ $self = shift;
  my $data = shift;

  if ( exists( $self->{subs}{$data->[1]} ) ) {
    my $sub = $self->{subs}{$data->[1]};
    if ( exists( $sub->{on_message} ) ) {
      if ( $data->[0] eq 'message' ) {
        $sub->{on_message}->( $data->[1], $data->[2] );
      }
      else {
        $sub->{on_message}->( $data->[2], $data->[3], $data->[1] );
      }
    }
  }
  else {
    $self->{on_error}->( "Don't known how process published message."
        . " Unknown channel or pattern '$data->[1]'", E_UNEXPECTED_DATA );
  }

  return;
}

####
sub _process_cmd_error {
  my __PACKAGE__ $self = shift;
  my $err_msg = shift;

  my $cmd = shift( @{$self->{processing_queue}} );
  if ( defined( $cmd ) ) {
    my $err_code;
    if ( index( $err_msg, 'NOSCRIPT' ) == 0 ) {
      $err_code = E_NO_SCRIPT;
      if ( exists( $cmd->{script} ) ) {
        $cmd->{args}[0] = $cmd->{script},
        $self->_push_to_handle( {
          name => 'eval',
          args => $cmd->{args},
          on_done => $cmd->{on_done},
          on_error => $cmd->{on_error},
        } );

        return;
      }
    }
    elsif ( index( $err_msg, 'LOADING' ) == 0 ) {
      $err_code = E_LOADING_DATASET;
    }
    elsif ( $err_msg eq 'ERR invalid password' ) {
      $err_code = E_INVALID_PASS;
    }
    elsif ( $err_msg eq 'ERR operation not permitted' ) {
      $err_code = E_OPRN_NOT_PERMITTED;
    }
    else {
      $err_code = E_OPRN_ERROR;
    }
    $cmd->{on_error}->( $err_msg, $err_code );
  }
  else {
    $self->{on_error}->( "Don't known how process error message '$err_msg'."
        . " Command queue is empty", E_UNEXPECTED_DATA );
  }

  return;
}

####
sub _process_sub_action {
  my __PACKAGE__ $self = shift;
  my $cmd = shift;
  my $data = shift;

  if ( exists( $SUB_CMDS{$cmd->{name}} ) ) {
    my $sub = {};
    if ( defined( $cmd->{on_done} ) ) {
      $sub->{on_done} = $cmd->{on_done};
      $sub->{on_done}->( $data->[1], $data->[2] );
    }
    if ( defined( $cmd->{on_message} ) ) {
      $sub->{on_message} = $cmd->{on_message};
    }
    $self->{subs}{$data->[1]} = $sub;
  }
  else {
    if ( defined( $cmd->{on_done} ) ) {
      $cmd->{on_done}->( $data->[1], $data->[2] );
    }
    if ( exists( $self->{subs}{$data->[1]} ) ) {
      delete( $self->{subs}{$data->[1]} );
    }
  }

  if ( --$cmd->{resp_remaining} == 0 ) {
    shift( @{$self->{processing_queue}} );
  }

  return;
}

####
sub _is_pub_message {
  my $data = pop;

  return ( ref( $data ) eq 'ARRAY' and ( $data->[0] eq 'message'
      or $data->[0] eq 'pmessage' ) );
}

####
sub _exec_command {
  my __PACKAGE__ $self = shift;
  my $cmd_name = shift;
  my @args = @_;
  my $params = {};
  if ( ref( $args[-1] ) eq 'HASH' ) {
    $params = pop( @args );
  }

  $params = $self->_validate_common_cbs( $params );

  my $cmd;
  if ( $cmd_name eq 'eval_cached' ) {
    my $sha1_hash;
    my $script = $args[0];
    if ( !exists( $EVAL_CACHE{$script} ) ) {
      $sha1_hash = sha1_hex( $script );
      $EVAL_CACHE{$script} = $sha1_hash;
    }
    $args[0] = $EVAL_CACHE{$script};

    $cmd = {
      name => 'evalsha',
      args => \@args,
      on_done => $params->{on_done},
      on_error => $params->{on_error},
      script => $script,
    };
  }
  else {
    $cmd = {
      name => $cmd_name,
      args => \@args,
      on_done => $params->{on_done},
      on_error => $params->{on_error},
    };

    if ( exists( $SUB_UNSUB_CMDS{$cmd_name} ) ) {
      if ( exists( $SUB_CMDS{$cmd_name} ) ) {
        $cmd->{on_message} = $self->_validate_message_cb( $params->{on_message} );
      }
      if ( $self->{sub_lock} ) {
        $self->_async_call(
          sub {
            $cmd->{on_error}->( "Command '$cmd_name' not allowed after 'multi' command."
                . ' First, the transaction must be completed', E_OPRN_ERROR );
          }
        );

        return;
      }
      $cmd->{resp_remaining} = scalar( @{$cmd->{args}} );
    }
    elsif ( $cmd_name eq 'multi' ) {
      $self->{sub_lock} = 1;
    }
    elsif ( $cmd_name eq 'exec' ) {
      $self->{sub_lock} = 0;
    }
  }

  if ( !defined( $self->{handle} ) ) {
    if ( $self->{reconnect} ) {
      $self->_connect();
    }
    else {
      $self->_async_call(
        sub {
          $cmd->{on_error}->( "Can't handle the command '$cmd_name'."
              . ' No connection to the server', E_NO_CONN );
        }
      );

      return;
    }
  }
  if ( $self->{connected} ) {
    if ( $self->{auth_status} == S_IS_DONE ) {
      if ( $self->{db_select_status} == S_IS_DONE ) {
        $self->_push_to_handle( $cmd );
      }
      else {
        if ( $self->{db_select_status} == S_NEED_PERFORM ) {
          $self->_select_db();
        }
        push( @{$self->{buffer}}, $cmd );
      }
    }
    else {
      if ( $self->{auth_status} == S_NEED_PERFORM ) {
        $self->_auth();
      }
      push( @{$self->{buffer}}, $cmd );
    }
  }
  else {
    push( @{$self->{buffer}}, $cmd );
  }

  return;
}

####
sub _validate_common_cbs {
  my __PACKAGE__ $self = shift;
  my $params = shift;

  foreach my $name ( qw( on_done on_error ) ) {
    if (
      defined( $params->{$name} )
        and ( !ref( $params->{$name} ) or ref( $params->{$name} ) ne 'CODE' )
        ) {
      confess "'$name' callback must be a code reference";
    }
  }

  if ( !defined( $params->{on_error} ) ) {
    $params->{on_error} = $self->{on_error};
  }

  return $params;
}

####
sub _validate_message_cb {
  my $cb = pop;

  if ( defined( $cb ) and ( !ref( $cb ) or ref( $cb ) ne 'CODE' ) ) {
    confess "'on_message' callback must be a code reference";
  }

  return $cb;
}

####
sub _auth {
  my __PACKAGE__ $self = shift;
  weaken( $self );

  $self->{auth_status} = S_IN_PROGRESS;
  $self->_push_to_handle( {
    name => 'auth',
    args => [ $self->{password} ],
    on_done => sub {
      $self->{auth_status} = S_IS_DONE;
      if ( $self->{db_select_status} == S_NEED_PERFORM ) {
        $self->_select_db();
      }
      else {
        $self->_flush_buffer();
      }
    },

    on_error => sub {
      my $err_msg = shift;
      my $err_code = shift;

      $self->{auth_status} = S_NEED_PERFORM;
      $self->_abort_all( $err_msg, $err_code );
      $self->{on_error}->( $err_msg, $err_code );
    },
  } );

  return;
}

####
sub _select_db {
  my __PACKAGE__ $self = shift;
  weaken( $self );

  $self->{db_select_status} = S_IN_PROGRESS;
  $self->_push_to_handle( {
    name => 'select',
    args => [ $self->{database} ],
    on_done => sub {
      $self->{db_select_status} = S_IS_DONE;
      $self->_flush_buffer();
    },

    on_error => sub {
      my $err_msg = shift;
      my $err_code = shift;

      $self->{db_select_status} = S_NEED_PERFORM;
      $self->_abort_all( $err_msg, $err_code );
      $self->{on_error}->( $err_msg, $err_code );
    },
  } );

  return;
}

####
sub _flush_buffer {
  my __PACKAGE__ $self = shift;

  my @commands = @{$self->{buffer}};
  $self->{buffer} = [];
  foreach my $cmd ( @commands ) {
    $self->_push_to_handle( $cmd );
  }

  return;
}

####
sub _push_to_handle {
  my __PACKAGE__ $self = shift;
  my $cmd = shift;

  push( @{$self->{processing_queue}}, $cmd );
  my $cmd_str = '';
  my $mbulk_len = 0;
  foreach my $token ( $cmd->{name}, @{$cmd->{args}} ) {
    if ( defined( $token ) and $token ne '' ) {
      if ( defined( $self->{encoding} ) and is_utf8( $token ) ) {
        $token = $self->{encoding}->encode( $token );
      }
      my $token_len = length( $token );
      $cmd_str .= "\$$token_len" . EOL . $token . EOL;
      ++$mbulk_len;
    }
  }
  $cmd_str = "*$mbulk_len" . EOL . $cmd_str;
  $self->{handle}->push_write( $cmd_str );

  return;
}

####
sub _abort_all {
  my __PACKAGE__ $self = shift;
  my $err_msg = shift;
  my $err_code = shift;

  $self->{sub_lock} = 0;
  $self->{subs} = {};
  my @commands;
  if ( @{$self->{buffer}} ) {
    @commands =  @{$self->{buffer}};
    $self->{buffer} = [];
  }
  elsif ( @{$self->{processing_queue}} ) {
    @commands =  @{$self->{processing_queue}};
    $self->{processing_queue} = [];
  }
  foreach my $cmd ( @commands ) {
    $cmd->{on_error}->( "Command '$cmd->{name}' aborted: $err_msg", $err_code );
  }

  return;
}

####
sub _async_call {
  my __PACKAGE__$self = shift;
  my $cb = shift;

  my $timer;
  $timer = AnyEvent->timer(
    after => 0,
    cb => sub {
      undef( $timer );
      $cb->();
    },
  );

  return;
}

####
sub AUTOLOAD {
  our $AUTOLOAD;
  my $cmd_name = $AUTOLOAD;
  $cmd_name =~ s/^.+:://o;
  $cmd_name = lc( $cmd_name );

  my $sub = sub {
    my __PACKAGE__ $self = shift;
    $self->_exec_command( $cmd_name, @_ );
  };

  do {
    no strict 'refs';
    *{$AUTOLOAD} = $sub;
  };

  goto &{$sub};
}

####
sub DESTROY {}

1;
__END__

=head1 NAME

AnyEvent::Redis::RipeRedis - Flexible non-blocking Redis client with reconnect
feature

=head1 SYNOPSIS

  use AnyEvent;
  use AnyEvent::Redis::RipeRedis qw( :err_codes );

  my $cv = AnyEvent->condvar();

  my $redis = AnyEvent::Redis::RipeRedis->new(
    host => 'localhost',
    port => '6379',
    password => 'your_password',
    encoding => 'utf8',

    on_connect => sub {
      print "Connected to Redis server\n";
    },

    on_disconnect => sub {
      print "Disconnected from Redis server\n";
    },

    on_error => sub {
      my $err_msg = shift;
      my $err_code = shift;
      warn "$err_msg. Error code: $err_code\n";
    },
  );

  # Set value
  $redis->set( 'foo', 'Some string', {
    on_done => sub {
      my $data = shift;
      print "$data\n";
      $cv->send();
    },

    on_error => sub {
      my $err_msg = shift;
      my $err_code = shift;

      if (
        $err_code == E_CANT_CONN
          or $err_code == E_LOADING_DATASET
          or $err_code == E_IO
          or $err_code == E_CONN_CLOSED_BY_REMOTE_HOST
          ) {
        # Trying repeat operation
      }
      else {
        $cv->croak( "$err_msg. Error code: $err_code" );
      }
    }
  } );

  $cv->recv();

  $redis->disconnect();

=head1 DESCRIPTION

AnyEvent::Redis::RipeRedis is a non-blocking flexible Redis client with reconnect
feature. It supports subscriptions, transactions, has simple API and it faster
than AnyEvent::Redis.

Requires Redis 1.2 or higher, and any supported event loop.

=head1 CONSTRUCTOR

=head2 new()

  my $redis = AnyEvent::Redis::RipeRedis->new(
    host => 'localhost',
    port => '6379',
    password => 'your_password',
    database => 7,
    lazy => 1,
    connection_timeout => 5,
    reconnect => 1,
    encoding => 'utf8',

    on_connect => sub {
      print "Connected to Redis server\n";
    },

    on_disconnect => sub {
      print "Disconnected from Redis server\n";
    },

    on_connect_error => sub {
      my $err_msg = shift;
      warn "$err_msg\n";
    },

    on_error => sub {
      my $err_msg = shift;
      my $err_code = shift;
      warn "$err_msg. Error code: $err_code\n";
    },
  );

=over

=item host

Server hostname (default: 127.0.0.1)

=item port

Server port (default: 6379)

=item password

Authentication password. If it specified, then C<AUTH> command will be executed
immediately after connection and after every reconnection.

=item database

Database index. If it set, then client will be switched to specified database
immediately after connection and after every reconnection. Default database
index is C<0>.

=item connection_timeout

Connection timeout. If after this timeout client could not connect to the server,
callback C<on_error> is called. By default used kernel's connection timeout.

=item lazy

If this parameter is set, then connection will be established, when you will send
a first command to the server. By default connection establishes after calling
method C<new>.

=item reconnect

If this parameter is TRUE and connection to the Redis server was lost, then
client will try to reconnect to server while executing next command. Client
try to reconnect only once and if fails, calls C<on_error> callback. If
you need several attempts of reconnection, just retry command from C<on_error>
callback as many times, as you need. This feature made client more responsive.

By default is TRUE.

=item encoding

Used to decode and encode strings during input/output operations. Not set by
default.

=item on_connect => $cb->()

Callback C<on_connect> is called, when connection is established. Not set by
default.

=item on_disconnect => $cb->()

Callback C<on_disconnect> is called, when connection is closed. Not set by
default.

=item on_connect_error => $cb->( $err_msg )

Callback C<on_connect_error> is called, when the connection could not be
established. If this collback isn't specified, then C<on_error> callback is
called.

=item on_error => $cb->( $err_msg, $err_code )

Callback C<on_error> is called, when any error occurred. If callback is no set
just prints error message to C<STDERR>.

=back

=head1 COMMAND EXECUTION

=head2 <command>( [ @args[, \%params ] ] )

  # Set value
  $redis->set( 'foo', 'Some string' );

  # Increment
  $redis->incr( 'bar', {
    on_done => sub {
      my $data = shift;
      print "$data\n";
    },
  } );

  # Get list of values
  $redis->lrange( 'list', 0, -1, {
    on_done => sub {
      my $data = shift;
      foreach my $val ( @{ $data } ) {
        print "$val\n";
      }
    },

    on_error => sub {
      my $err_msg = shift;
      my $err_code = shift;
      $cv->croak( "$err_msg. Error code: $err_code" );
    },
  } );

Full list of Redis commands can be found here: L<http://redis.io/commands>

=over

=item on_done => $cb->( $data )

Callback C<on_done> is called, when command handling is done.

=item on_error => $cb->( $err_msg, $err_code )

Callback C<on_error> is called, when any error occurred.

=back

=head1 SUBSCRIPTIONS

=head2 subscribe( @channels[, \%params ] )

Subscribe to channels by name.

  $redis->subscribe( qw( ch_foo ch_bar ), {
    on_done =>  sub {
      my $ch_name = shift;
      my $subs_num = shift;
      print "Subscribed: $ch_name. Active: $subs_num\n";
    },

    on_message => sub {
      my $ch_name = shift;
      my $msg = shift;
      print "$ch_name: $msg\n";
    },
  } );

=over

=item on_done => $cb->( $ch_name, $sub_num )

Callback C<on_done> is called, when subscription is done.

=item on_message => $cb->( $ch_name, $msg )

Callback C<on_message> is called, when published message is received.

=item on_error => $cb->( $err_msg, $err_code )

Callback C<on_error> is called, when any error occurred.

=back

=head2 psubscribe( @patterns[, \%params ] )

Subscribe to group of channels by pattern.

  $redis->psubscribe( qw( info_* err_* ), {
    on_done =>  sub {
      my $ch_pattern = shift;
      my $subs_num = shift;
      print "Subscribed: $ch_pattern. Active: $subs_num\n";
    },

    on_message => sub {
      my $ch_name = shift;
      my $msg = shift;
      my $ch_pattern = shift;
      print "$ch_name ($ch_pattern): $msg\n";
    },

    on_error => sub {
      my $err_msg = shift;
      warn "$err_msg\n";
    },
  } );

=over

=item on_done => $cb->( $ch_pattern, $sub_num )

Callback C<on_done> is called, when subscription is done.

=item on_message => $cb->( $ch_name, $msg, $ch_pattern )

Callback C<on_message> is called, when published message is received.

=item on_error => $cb->( $err_msg, $err_code )

Callback C<on_error> is called, when any error occurred.

=back


=head2 unsubscribe( @channels[, \%params ] )

Unsubscribe from channels by name.

  $redis->unsubscribe( qw( ch_foo ch_bar ), {
    on_done => sub {
      my $ch_name = shift;
      my $subs_num = shift;
      print "Unsubscribed: $ch_name. Active: $subs_num\n";
    },

    on_error => sub {
      my $err_msg = shift;
      warn "$err_msg\n";
    },
  } );

=over

=item on_done => $cb->( $ch_name, $sub_num )

Callback C<on_done> is called, when unsubscription is done.

=item on_error => $cb->( $err_msg, $err_code )

Callback C<on_error> is called, when any error occurred.

=back

=head2 punsubscribe( @patterns[, \%params ] )

Unsubscribe from group of channels by pattern.

  $redis->punsubscribe( qw( info_* err_* ), {
    on_done => sub {
      my $ch_pattern = shift;
      my $subs_num = shift;
      print "Unsubscribed: $ch_pattern. Active: $subs_num\n";
    },

    on_error => sub {
      my $err_msg = shift;
      warn "$err_msg\n";
    },
  } );

=over

=item on_done => $cb->( $ch_pattern, $sub_num )

Callback C<on_done> is called, when unsubscription is done.

=item on_error => $cb->( $err_msg, $err_code )

Callback C<on_error> is called, when any error occurred.

=back


=head1 CONNECTION VIA UNIX-SOCKET

Redis 2.2 and higher support connection via UNIX domain socket. To connect via
a UNIX-socket in the parameter C<host> you have to specify C<unix/>, and in
the parameter C<port> you have to specify the path to the socket.

  my $redis = AnyEvent::Redis::RipeRedis->new(
    host => 'unix/',
    port => '/tmp/redis.sock',
  );

=head1 ERROR CODES

Error codes can be used for programmatic handling of errors.

  1  - E_CANT_CONN
  2  - E_LOADING_DATASET
  3  - E_IO
  4  - E_CONN_CLOSED_BY_REMOTE_HOST
  5  - E_CONN_CLOSED_BY_CLIENT
  6  - E_NO_CONN
  7  - E_INVALID_PASS
  8  - E_OPRN_NOT_PERMITTED
  9  - E_OPRN_ERROR
  10 - E_UNEXPECTED_DATA
  11 - E_NO_SCRIPT

=over

=item E_CANT_CONN

Can't connect to server.

=item E_LOADING_DATASET

Redis is loading the dataset in memory.

=item E_IO

Input/Output operation error. Connection closed.

=item E_CONN_CLOSED_BY_REMOTE_HOST

Connection closed by remote host.

=item E_CONN_CLOSED_BY_CLIENT

Connection closed unexpectedly by client.

Error occur if at time of disconnection in client queue were uncompleted commands.

=item E_NO_CONN

No connection to the server.

Error occur if at time of command execution connection has been closed by any
reason and parameter C<reconnect> was set to FALSE.

=item E_INVALID_PASS

Invalid password.

=item E_OPRN_NOT_PERMITTED

Operation not permitted. Authentication required.

=item E_OPRN_ERROR

Operation error. Usually returned by the Redis server.

=item E_UNEXPECTED_DATA

Client received unexpected data from server.

=item E_NO_SCRIPT

No matching script. Use C<EVAL> command.

=back

To use these constants you have to import them.

  use AnyEvent::Redis::RipeRedis qw( :err_codes );

=head1 DISCONNECTION

When the connection to the server is no longer needed you can close it in three
ways: call method C<disconnect()>, send C<QUIT> command or you can just "forget"
any references to an AnyEvent::Redis::RipeRedis object, but in this case client
object destroying silently without calling any callbacks including C<on_disconnect>
callback to avoid unexpected behavior.

=head2 disconnect()

Method for synchronous disconnection.

  $redis->disconnect();

=head1 SEE ALSO

L<AnyEvent>, L<AnyEvent::Redis>, L<Redis>

=head1 AUTHOR

Eugene Ponizovsky, E<lt>ponizovsky@gmail.comE<gt>

=head2 Special thanks

=over

=item *

Alexey Shrub

=item *

Vadim Vlasov

=item *

Konstantin Uvarin

=back

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2012, Eugene Ponizovsky, E<lt>ponizovsky@gmail.comE<gt>. All rights
reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
