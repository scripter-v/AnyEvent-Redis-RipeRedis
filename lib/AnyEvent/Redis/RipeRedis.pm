package AnyEvent::Redis::RipeRedis;

use 5.010000;
use strict;
use warnings;

use fields qw(
  host
  port
  password
  encoding
  reconnect
  reconnect_after
  max_connect_attempts
  on_connect
  on_stop_reconnect
  on_connect_error
  on_redis_error
  on_error
  handle
  connect_attempt
  commands_queue
  sub_lock
  subs
);

our $VERSION = '0.500000';

use AnyEvent::Handle;
use Encode qw( find_encoding is_utf8 );
use Scalar::Util 'looks_like_number';
use Carp qw( croak confess );

my $DEFAULT = {
  host => 'localhost',
  port => '6379',
  reconnect_after => 5,
};

my $EOL = "\r\n";
my $EOL_LENGTH = length( $EOL );


# Constructor
sub new {
  my $proto = shift;

  my %params;

  if ( ref( $_[ 0 ] ) eq 'HASH' ) {
    %params = %{ shift() };
  }
  else {
    %params = @_;
  }

  my $class = ref( $proto ) || $proto;
  my $self = fields::new( $class );

  $self->{host} = $params{host} || $DEFAULT->{host};
  $self->{port} = $params{port} || $DEFAULT->{port};
  $self->{password} = $params{password};

  if ( defined( $params{encoding} ) ) {
    $self->{encoding} = find_encoding( $params{encoding} );

    if ( !defined( $self->{encoding} ) ) {
      croak "Encoding \"$params{encoding}\" not found";
    }
  }

  $self->{reconnect} = $params{reconnect};

  if ( $self->{reconnect} ) {

    if ( defined( $params{reconnect_after} ) ) {

      if ( !looks_like_number( $params{reconnect_after} )
        || $params{reconnect_after} <= 0 ) {

        croak '"reconnect_after" must be a positive number';
      }

      $self->{reconnect_after} = $params{reconnect_after};
    }
    else {
      $self->{reconnect_after} = $DEFAULT->{reconnect_after};
    }

    if ( defined( $params{max_connect_attempts} ) ) {

      if ( $params{max_connect_attempts} =~ m/[^0-9]/o
        || $params{max_connect_attempts} <= 0 ) {

        croak '"max_connect_attempts" must be a positive integer number';
      }

      $self->{max_connect_attempts} = $params{max_connect_attempts};
    }
  }

  my @cb_names = qw( on_connect on_stop_reconnect on_connect_error
      on_redis_error on_error );

  foreach my $cb_name ( @cb_names ) {

    if ( defined( $params{ $cb_name } ) ) {

      if ( ref( $params{ $cb_name } ) ne 'CODE' ) {
        croak "\"$cb_name\" callback must be a CODE reference";
      }

      $self->{ $cb_name } = $params{ $cb_name };
    }
  }

  if ( !defined( $self->{on_error} ) ) {
    $self->{on_error} = sub { warn shift . "\n"; };
  }

  $self->{handle} = undef;
  $self->{connect_attempt} = 0;
  $self->{commands_queue} = [];
  $self->{sub_lock} = undef;
  $self->{subs} = {};

  $self->_connect();

  return $self;
}


# Private methods

####
sub _connect {
  my $self = shift;

  ++$self->{connect_attempt};

  $self->{handle} = AnyEvent::Handle->new(
    connect => [ $self->{host}, $self->{port} ],
    keepalive => 1,

    on_connect => sub {

      if ( exists( $self->{on_connect} ) ) {
        $self->{on_connect}->( $self->{connect_attempt} );
      }

      $self->{connect_attempt} = 0;
    },

    on_connect_error => sub {
      my $msg = pop;

      $self->_clean();

      $msg = "Can't connect to $self->{host}:$self->{port}; $msg";

      if ( exists( $self->{on_connect_error} ) ) {
        $self->{on_connect_error}->( $msg, $self->{connect_attempt} );
      }
      else {
        $self->{on_error}->( $msg );
      }

      $self->_attempt_to_reconnect();
    },

    on_error => sub {
      my $msg = pop;

      $self->_clean();
      $self->{on_error}->( $msg );
      $self->_attempt_to_reconnect();
    },

    on_eof => sub {
      $self->{on_error}->( 'Connection lost' );

      $self->_clean();
      $self->_attempt_to_reconnect();
    },

    on_read => $self->_prepare_on_read_cb( sub {
      return $self->_prcoess_response( @_ );
    } )
  );

  if ( defined( $self->{password} ) && $self->{password} ne '' ) {
    $self->_push_command( {
      name => 'auth',
      args => [ $self->{password} ]
    } );
  }

  return;
}

####
sub _exec_command {
  my $self = shift;
  my $cmd_name = shift;

  if ( !defined( $self->{handle} ) ) {
    $self->{on_error}->( "Can't execute command \"$cmd_name\". "
        . 'Connection not established' );

    return;
  }

  my $cb;
  my $params = {};

  if ( ref( $_[ -1 ] ) eq 'CODE' ) {
    $cb = pop;
  }
  elsif ( ref( $_[ -1 ] ) eq 'HASH' ) {
    $params = pop;
  }

  my @args = @_;

  my $cmd = {
    name => $cmd_name,
    args => \@args,
  };

  if ( $cmd_name eq 'subscribe' || $cmd_name eq 'psubscribe'
      || $cmd_name eq 'unsubscribe' || $cmd_name eq 'punsubscribe' ) {

    if ( $cmd_name eq 'subscribe' || $cmd_name eq 'psubscribe' ) {

      if ( defined( $cb ) ) {
        $cmd->{on_message} = $cb;
      }
      else {

        if ( defined( $params->{on_subscribe} ) ) {

          if ( ref( $params->{on_subscribe} ) ne 'CODE' ) {
            croak '"on_subscribe" callback must be a CODE reference';
          }

          $cmd->{on_subscribe} = $params->{on_subscribe};
        }

        if ( defined( $params->{on_message} ) ) {

          if ( ref( $params->{on_message} ) ne 'CODE' ) {
            croak '"on_message" callback must be a CODE reference';
          }

          $cmd->{on_message} = $params->{on_message};
        }
      }
    }
    else {

      if ( defined( $cb ) ) {
        $cmd->{cb} = $cb;
      }
    }
  }
  else {

    if ( defined( $cb ) ) {
      $cmd->{cb} = $cb;
    }

    if ( $cmd_name eq 'multi' ) {
      $self->{sub_lock} = 1;
    }
    elsif ( $cmd_name eq 'exec' ) {
      undef( $self->{sub_lock} );
    }
  }


  if ( $cmd_name eq 'multi' ) {
    $self->{sub_lock} = 1;
  }
  elsif ( $cmd_name eq 'exec' ) {
    undef( $self->{sub_lock} );
  }
  elsif ( $cmd_name eq 'subscribe' || $cmd_name eq 'psubscribe'
      || $cmd_name eq 'unsubscribe' || $cmd_name eq 'punsubscribe' ) {

    if ( $self->{sub_lock} ) {
      croak "Command \"$cmd_name\" not allowed in this context."
          . " First, the transaction must be completed.";
    }

    if ( $cmd_name eq 'subscribe' || $cmd_name eq 'psubscribe' ) {


    }

    $cmd->{resp_remaining} = scalar( @args );
  }

  $self->_push_command( $cmd );

  return;
}

####
sub _push_command {
  my $self = shift;
  my $cmd = shift;

  push( @{ $self->{commands_queue} }, $cmd );

  if ( defined( $self->{handle} ) ) {
    my $cmd_szd = $self->_serialize_command( $cmd );
    $self->{handle}->push_write( $cmd_szd );
  }

  return;
}

####
sub _serialize_command {
  my $self = shift;
  my $cmd = shift;

  my $bulk_len = scalar( @{ $cmd->{args} } ) + 1;
  my $cmd_szd = "*$bulk_len$EOL";

  foreach my $tkn ( $cmd->{name}, @{ $cmd->{args} } ) {

    if ( exists( $self->{encoding} ) && is_utf8( $tkn ) ) {
      $tkn = $self->{encoding}->encode( $tkn );
    }

    if ( defined( $tkn ) ) {
      my $tkn_len =  length( $tkn );
      $cmd_szd .= "\$$tkn_len$EOL$tkn$EOL";
    }
    else {
      $cmd_szd .= "\$-1$EOL";
    }
  }

  return $cmd_szd;
}

####
sub _prepare_on_read_cb {
  my $self = shift;
  my $cb = shift;

  my $bulk_len;

  return sub {
    my $hdl = shift;

    while ( 1 ) {

      if ( defined( $bulk_len ) ) {
        my $bulk_eol_len = $bulk_len + $EOL_LENGTH;

        if ( length( substr( $hdl->{rbuf}, 0, $bulk_eol_len ) ) == $bulk_eol_len ) {
          my $data = substr( $hdl->{rbuf}, 0, $bulk_len, '' );
          substr( $hdl->{rbuf}, 0, $EOL_LENGTH, '' );

          chomp( $data );

          if ( $self->{encoding} ) {
            $data = $self->{encoding}->decode( $data );
          }

          undef( $bulk_len );

          return 1 if $cb->( $data );
        }
        else {
          return;
        }
      }

      my $eol_pos = index( $hdl->{rbuf}, $EOL );

      if ( $eol_pos >= 0 ) {
        my $data = substr( $hdl->{rbuf}, 0, $eol_pos, '' );
        my $type = substr( $data, 0, 1, '' );
        substr( $hdl->{rbuf}, 0, $EOL_LENGTH, '' );

        if ( $type eq '+' || $type eq ':' ) {
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
            my $data_remaining = $mbulk_len;

            my @data_list;
            my $on_read_cb;

            my $on_data_cb = sub {
              my $data_el = shift;
              my $is_err = shift;

              if ( $is_err ) {
                $self->_on_redis_error( $data_el );
              }
              else {
                push( @data_list, $data_el );
              }

              --$data_remaining;

              if ( ref( $data_el ) eq 'ARRAY' && @{ $data_el } && $data_remaining > 0 ) {
                $hdl->unshift_read( $on_read_cb );
              }
              elsif ( $data_remaining == 0 ) {
                undef( $on_read_cb );

                $cb->( \@data_list );

                return 1;
              }
            };

            $on_read_cb = $self->_prepare_on_read_cb( $on_data_cb );
            $hdl->unshift_read( $on_read_cb );

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
      else {
        return;
      }
    }
  };
}

####
sub _prcoess_response {
  my $self = shift;
  my $data = shift;
  my $is_err = shift;

  if ( $is_err ) {
    $self->_on_redis_error( $data );

    shift( @{ $self->{commands_queue} } );

    return;
  }

  if ( %{ $self->{subs} } ) {

    if ( ref( $data ) eq 'ARRAY' ) {

      if ( ( $data->[ 0 ] eq 'message' || $data->[ 0 ] eq 'pmessage' )
        && exists( $self->{subs}{ $data->[ 1 ] } ) ) {

        my $cb_group = $self->{subs}{ $data->[ 1 ] };

        if ( $data->[ 0 ] eq 'message' ) {
          $cb_group->{on_message}->( $data->[ 1 ], $data->[ 2 ] );
        }
        else {
          $cb_group->{on_message}->( $data->[ 2 ], $data->[ 3 ], $data->[ 1 ] );
        }

        return;
      }
    }
  }

  my $cmd = $self->{commands_queue}->[ 0 ];

  if ( !defined( $cmd ) ) {
    $self->{on_error}->( 'Unexpected data in response' );

    return;
  }

  if ( $cmd->{name} eq 'subscribe' || $cmd->{name} eq 'psubscribe'
      || $cmd->{name} eq 'unsubscribe' || $cmd->{name} eq 'punsubscribe' ) {

    if ( $cmd->{name} eq 'subscribe' || $cmd->{name} eq 'psubscribe' ) {
      my $cb_group = {};

      if ( exists( $cmd->{on_subscribe} ) ) {
        $cb_group->{on_subscribe} = $cmd->{on_subscribe};
        $cb_group->{on_subscribe}->( $data->[ 1 ], $data->[ 2 ] );
      }

      if ( exists( $cmd->{on_message} ) ) {
        $cb_group->{on_message} = $cmd->{on_message};
      }

      $self->{subs}{ $data->[ 1 ] } = $cb_group;
    }
    else {

      if ( exists( $cmd->{cb} ) ) {
        $cmd->{cb}->( $data->[ 1 ], $data->[ 2 ] );
      }

      if ( exists( $self->{subs}{ $data->[ 1 ] } ) ) {
        delete( $self->{subs}{ $data->[ 1 ] } );
      }
    }

    if ( --$cmd->{resp_remaining} == 0 ) {
      shift( @{ $self->{commands_queue} } );
    }

    return;
  }

  if ( exists( $cmd->{cb} ) ) {
    $cmd->{cb}->( $data );
  }

  if ( $cmd->{name} eq 'quit' ) {
    $self->_clean();

    return;
  }

  shift( @{ $self->{commands_queue} } );

  return;
}

####
sub _on_redis_error {
  my $self = shift;
  my $msg = shift;

  if ( exists( $self->{on_redis_error} ) ) {
    $self->{on_redis_error}->( $msg );
  }
  else {
    $self->{on_error}->( $msg );
  }

  return;
}

####
sub _attempt_to_reconnect {
  my $self = shift;

  if ( $self->{reconnect} && ( !defined( $self->{max_connect_attempts} )
    || $self->{connect_attempt} < $self->{max_connect_attempts} ) ) {

    $self->_reconnect();
  }
  else {

    if ( defined( $self->{on_stop_reconnect} ) ) {
      $self->{on_stop_reconnect}->();
    }
  }

  return;
}

####
sub _reconnect {
  my $self = shift;

  if ( $self->{connect_attempt} > 0 ) {
    my $timer;

    $timer = AnyEvent->timer(
      after => $self->{reconnect_after},
      cb => sub {
        undef( $timer );

        $self->_connect();
      }
    );
  }
  else {
    $self->_connect();
  }

  return;
}

####
sub _clean {
  my $self = shift;

  undef( $self->{handle} );
  $self->{commands_queue} = [];
  undef( $self->{sub_lock} );
  $self->{subs} = {};

  return;
}


####
sub AUTOLOAD {
  our $AUTOLOAD;

  my $cmd_name = $AUTOLOAD;
  $cmd_name =~ s/^.+:://o;
  $cmd_name = lc( $cmd_name );

  my $sub = sub {
    my $self = shift;

    $self->_exec_command( $cmd_name, @_ );
  };

  do {
    no strict 'refs';

    *{ $AUTOLOAD } = $sub;
  };

  goto &{ $sub };
}


####
sub DESTROY {
  my $self = shift;

  $self->_clean();

  return;
}

1;
__END__

=head1 NAME

AnyEvent::Redis::RipeRedis - Non-blocking Redis client with self reconnect feature on
loss connection

=head1 SYNOPSIS

  use AnyEvent::Redis::RipeRedis;

=head1 DESCRIPTION

This module is an AnyEvent user, you need to make sure that you use and run a
supported event loop.

AnyEvent::Redis::RipeRedis is non-blocking Redis client with self reconnect feature on
loss connection.

Module requires Redis 1.2 or higher.

=head1 METHODS

=head1 SEE ALSO

Redis, AnyEvent::Redis, AnyEvent

=head1 AUTHOR

Eugene Ponizovsky, E<lt>ponizovsky@gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2012, Eugene Ponizovsky, E<lt>ponizovsky@gmail.comE<gt>. All rights reserved.

This module is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
