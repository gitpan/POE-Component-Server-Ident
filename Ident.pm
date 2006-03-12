package POE::Component::Server::Ident;

use strict;
use warnings;
use POE qw( Wheel::SocketFactory Wheel::ReadWrite Driver::SysRW
            Filter::Line );
use Carp;
use Socket;
use vars qw($VERSION);

$VERSION = '0.3';

use constant PCSI_REFCOUNT_TAG => "P::C::S::I registered";

sub spawn {
  my $package = shift;
  my ($alias,$bindaddr,$bindport,$multiple,$timeout) = _parse_arguments(@_);

  croak "You must specify an Alias to $package->spawn" unless $alias;

  $bindport = 113 unless defined $bindport;
  $multiple = 0 unless defined $multiple;
  $timeout = 60 unless defined $timeout;

  my $self = $package->new($alias,$bindaddr,$bindport,$multiple,$timeout);

  POE::Session->create (
	object_states => [
		$self => { _start     => 'server_start',
			   _stop      => 'server_stop',
			   'shutdown' => 'server_close',
			 },
		$self => [ qw(add_connection del_connection accept_new_client accept_failed register unregister) ],
	],
  );
  return $self;
}

sub new {
  my $package = shift;
  my ($alias,$bindaddr,$bindport,$multiple,$timeout) = @_;

  my $self = { };

  $self->{Alias} = $alias;
  $self->{BindPort} = $bindport;
  $self->{BindAddr} = $bindaddr unless ( not defined ( $bindaddr ) );
  $self->{'Multiple'} = $multiple;
  $self->{'TimeOut'} = $timeout;

  return bless $self, $package;
}

sub getsockname {
  my $self = shift;
  return $self->{listener}->getsockname();
}

sub server_start {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  $kernel->alias_set( $self->{Alias} );

  $self->{listener} = POE::Wheel::SocketFactory->new ( 
			BindPort => $self->{BindPort},
			( $self->{BindAddr} ? (BindAddr => $self->{BindAddr}) : () ),
			Reuse => 'on',
			SuccessEvent => 'accept_new_client',
			FailureEvent => 'accept_failed',
                      );
  undef;
}

sub server_stop {
  my ($kernel,$self) = @_[KERNEL,OBJECT];
  # Hmmm server stopped blah blah blah
  undef;
}

sub server_close {
  my ($kernel,$self) = @_[KERNEL,OBJECT];

  foreach ( keys %{ $self->{clients} } ) {
	delete ( $self->{clients}->{ $_ }->{readwrite} );
  }
  delete ( $self->{listener} );
  $kernel->alias_remove( $self->{Alias} );
  undef;
}

sub accept_new_client {
  my ($kernel,$self,$socket,$peeraddr,$peerport) = @_[KERNEL,OBJECT,ARG0 .. ARG2];
  $peeraddr = inet_ntoa($peeraddr);

  # $self->{clients}->{ $peeraddr }->{ $peerport }->{Socket} = $socket;

  POE::Session->create (
	object_states => [
		$self => { _start => 'client_start',
			   _stop  => 'client_stop',
			 },
		$self => [ qw(client_input client_error client_done client_timeout client_default ident_server_reply ident_server_error) ],
	],
	args => [ $socket, $peeraddr, $peerport ],
  );
  undef;
}

sub accept_failed {
  my ($kernel,$self,$function,$error) = @_[KERNEL,OBJECT,ARG0,ARG2];
  my ($package) = ref $self;

  $kernel->call ( $self->{Alias} => 'shutdown' );

  warn "$package: call to $function() failed: $error";
  undef;
}

sub register {
  my ($kernel,$self,$sender,$session) = @_[KERNEL,OBJECT,SENDER,SESSION];
  $sender = $sender->ID();
  $session = $session->ID();

  $self->{sessions}->{$sender}->{'ref'} = $sender;
  unless ($self->{sessions}->{$sender}->{refcnt}++ or $session == $sender) {
      $kernel->refcount_increment($sender, PCSI_REFCOUNT_TAG);
  }
  undef;
}


sub unregister {
  my ($kernel,$self,$sender,$session) = @_[KERNEL,OBJECT,SENDER,SESSION];
  $sender = $sender->ID();
  $session = $session->ID();

  if (--$self->{sessions}->{$sender}->{refcnt} <= 0) {
      delete $self->{sessions}->{$sender};
      unless ($session == $sender) {
        $kernel->refcount_decrement($sender, PCSI_REFCOUNT_TAG);
      }
  }
  undef;
}

sub client_start {
  my ($kernel,$session,$self,$socket,$peeraddr,$peerport) = @_[KERNEL,SESSION,OBJECT,ARG0,ARG1,ARG2];
  
  $self->{clients}->{ $session->ID }->{Socket} = $socket;
  $self->{clients}->{ $session->ID }->{PeerAddr} = $peeraddr;
  $self->{clients}->{ $session->ID }->{PeerPort} = $peerport;

  $self->{clients}->{ $session->ID }->{readwrite} = 
  POE::Wheel::ReadWrite->new(
	Handle => $socket,
	Filter => POE::Filter::Line->new( Literal => "\x0D\x0A" ),
	InputEvent => 'client_input',
	ErrorEvent => 'client_error',
	( $self->{'Multiple'} == 1 ? () : ( FlushedEvent => 'client_timeout' ) ),
  );

  # Set a delay to close the connection if we are idle for 60 seconds.

  $kernel->delay ( 'client_timeout' => $self->{'TimeOut'} );
  undef;
}

sub client_stop {
  my ($kernel,$self,$session) = @_[KERNEL,OBJECT,SESSION];

  $kernel->delay ( 'client_timeout' => undef );
  delete $self->{clients}->{ $session->ID };
  undef;
}

sub client_input {
  my ($kernel,$self,$session,$input) = @_[KERNEL,OBJECT,SESSION,ARG0];

  # Parse what is passed. We want <number>,<number> or nothing.

  if ( $input =~ /^\s*([0-9]+)\s*,\s*([0-9]+)\s*$/ and _valid_ports($1,$2) ) {
    my ($port1) = $1; my ($port2) = $2;
    $self->{clients}->{ $session->ID }->{'Port1'} = $port1;
    $self->{clients}->{ $session->ID }->{'Port2'} = $port2;
    # Okay got a sort of valid query. Send it to all interested sessions.
    $kernel->call( $_ => 'identd_request' => $self->{clients}->{ $session->ID }->{PeerAddr} => $port1 => $port2 ) for keys %{ $self->{sessions} };
    $kernel->delay ( 'client_default' => 10 );
  } else {
    # Client sent us rubbish.
    $self->{clients}->{ $session->ID }->{readwrite}->put("0 , 0 : ERROR : INVALID-PORT");
  }
  $kernel->delay ( 'client_timeout' => $self->{'TimeOut'} ) if ( $self->{'Multiple'} );
  undef;
}

sub client_done {
  my ($kernel,$self,$session) = @_[KERNEL,OBJECT,SESSION];
  $kernel->delay ( 'client_timeout' => undef );
  delete $self->{clients}->{ $session->ID };
  undef;
}

sub client_error {
  my ($kernel,$self,$session) = @_[KERNEL,OBJECT,SESSION];
  $kernel->delay ( 'client_timeout' => undef );
  delete $self->{clients}->{ $session->ID }->{readwrite};
  undef;
}

sub client_timeout {
  my ($kernel,$self,$session) = @_[KERNEL,OBJECT,SESSION];
  $kernel->delay ( 'client_timeout' => undef );
  $kernel->delay ( 'client_default' => undef );
  delete $self->{clients}->{ $session->ID }->{readwrite};
  undef;
}

sub add_connection {
  my ($kernel,$self,$session) = @_[KERNEL,OBJECT,SESSION];
  undef;
}

sub del_connection {
  my ($kernel,$self,$session) = @_[KERNEL,OBJECT,SESSION];
  undef;
}

sub client_default {
  my ($kernel,$self,$session) = @_[KERNEL,OBJECT,SESSION];

  my ($reply) = $self->{clients}->{ $session->ID }->{'Port1'} . " , " . $self->{clients}->{ $session->ID }->{'Port2'} . " : ERROR : HIDDEN-USER";

  $self->{clients}->{ $session->ID }->{readwrite}->put($reply) if ( defined ( $self->{clients}->{ $session->ID }->{readwrite} ) );
  $kernel->delay ( 'client_timeout' => $self->{'TimeOut'} ) if ( $self->{'Multiple'} );
  undef;
}

sub ident_server_reply {
  my ($kernel,$self,$session) = @_[KERNEL,OBJECT,SESSION];

  my ($opsys,$userid) = @_[ARG0 .. ARG1];

  $opsys = "UNIX" unless defined ( $opsys );

  my ($reply) = $self->{clients}->{ $session->ID }->{'Port1'} . " , " . $self->{clients}->{ $session->ID }->{'Port2'} . " : USERID : " . $opsys . " : " . $userid;

  $self->{clients}->{ $session->ID }->{readwrite}->put($reply);
  $kernel->delay ( 'client_timeout' => $self->{'TimeOut'} ) if ( $self->{'Multiple'} );
  $kernel->delay ( 'client_default' => undef );
  undef;
}

sub ident_server_error {
  my ($kernel,$self,$session,$error_type) = @_[KERNEL,OBJECT,SESSION,ARG0];
  $error_type = uc $error_type;

  unless ( grep {$_ eq $error_type} qw(INVALID-PORT NO-USER HIDDEN-USER UNKNOWN-ERROR) ) {
	$error_type = 'UNKNOWN-ERROR';
  }

  my ($reply) = $self->{clients}->{ $session->ID }->{'Port1'} . " , " . $self->{clients}->{ $session->ID }->{'Port2'} . " : ERROR : " . $error_type;

  $self->{clients}->{ $session->ID }->{readwrite}->put($reply);
  $kernel->delay ( 'client_timeout' => $self->{'TimeOut'} ) if ( $self->{'Multiple'} );
  $kernel->delay ( 'client_default' => undef );
  undef;
}

sub _parse_arguments {
  my %arguments = @_;
  my @returns;

  # Extra stuff here if we want it. Maybe.
  $returns[0] = $arguments{'Alias'};
  $returns[1] = $arguments{'BindAddr'};
  $returns[2] = $arguments{'BindPort'} if ( defined ( $arguments{'BindPort'} ) and ( $arguments{'BindPort'} >= 0 and $arguments{'BindPort'} <= 65535 ) );
  $returns[3] = $arguments{'Multiple'} if ( defined ( $arguments{'Multiple'} ) and ( $arguments{'Multiple'} != 1 or $arguments{'Multiple'} == 0 ) );
  $returns[4] = $arguments{'TimeOut'} if ( defined ( $arguments{'TimeOut'} ) and ( $arguments{'TimeOut'} >= 30 and $arguments{'TimeOut'} <= 180 ) );
  return @returns;
}

sub _valid_ports {
  my ($port1,$port2) = @_;

  if ( ( defined ( $port1 ) and defined ( $port2 ) ) and ( $port1 >= 1 and $port1 <= 65535 ) and ( $port2 >= 1 and $port2 <= 65535 ) ) {
	return 1;
  }

  return 0;
}

=head1 NAME

POE::Component::Server::Ident - A component that provides non-blocking ident services to your sessions.

=head1 SYNOPSIS

   use POE::Component::Server::Ident;

   POE::Component::Server::Ident->spawn ( Alias => 'Ident-Server' );

   POE::Session->create ( 
		inline_states => {
					identd_request => \&ident_request_handler,
				 },
   );

   $kernel->post ( 'Ident-Server' => 'register' );

   $kernel->post ( 'Ident-Server' => 'unregister' );

   sub ident_request_handler {
      my ($kernel,$sender,$peeraddr,$port1,$port2) = @_[KERNEL,SENDER,ARG0,ARG1,ARG2];

      $kernel->call ( $sender => ident_server_reply => 'UNIX' => 'lameuser' );
   }

=head1 DESCRIPTION

POE::Component::Server::Ident is a POE ( Perl Object Environment ) component that provides 
a non-blocking Identd for other components and POE sessions.

Spawn the component, give it an alias and it will sit there waiting for Ident clients to connect.
Register with the component to receive ident events. The component will listen for client connections.
A valid ident request made by a client will result in an 'identd_server' event being sent to your 
session. You may send back 'ident_server_reply' or 'ident_server_error' depending on what the client
sent.

The component will automatically respond to the client requests with 'ERROR : HIDDEN-USER' if your 
sessions do not send a reponse within a 10 second timeout period.

=head1 METHODS

=over

=item spawn

Takes a number of arguments: 'Alias', a kernel alias to address the component with; 'BindAddr',
the IP address that the component should bind to, defaults to INADDR_ANY; 'BindPort', the port 
that the component will bind to, default is 113; 'Multiple', specify whether the component should
allow multiple ident queries from clients by setting this to 1, default is 0 which terminates client 
connections after a response has been sent; 'TimeOut', this is the idle timeout on client connections, 
default is 60 seconds, excepts values between 60 and 180 seconds.

=back

=head1 INPUT

The component accepts the following events:

=over

=item register

Takes no arguments. This registers your session with the component. The component will then send you 
'identd_request' events when clients make valid ident requests. See below.

=item unregister

Takes no arguments. This unregisters your session with the component.

=item ident_server_reply

Takes two arguments, the first is the 'opsys' field of the ident response, the second is the 'userid'. 

=item ident_server_error

Takes one argument, the error to return to the client.

=back

=head1 OUTPUT

The component will send the following events:

=over

=item identd_request

Sent by the component to 'registered' sessions when a client makes a valid ident request. ARG0 is
the IP address of the client, ARG1 and ARG2 are the ports as specified in the ident request. You 
can use the 'ident_server_reply' and 'ident_server_error' to respond to the client appropriately. Please
note, that you send these responses to $_[SENDER] not the kernel alias of the component.

=back

=head1 AUTHOR

Chris Williams, E<lt>chris@bingosnet.co.ukE<gt>

=head1 SEE ALSO

RFC 1413 L<http://www.faqs.org/rfcs/rfc1413.html>


