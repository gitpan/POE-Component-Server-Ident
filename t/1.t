# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl 1.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

#use Test::More tests => 1;
#BEGIN { use_ok('POE::Component::Client::Ident') };

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

my (@tests) = ( "not ok 2", "not ok 3" );

$|=1;
print "1..3\n";

use Socket;
use POE qw(Wheel::SocketFactory Wheel::ReadWrite);
use POE::Component::Server::Ident;

my ($identd) = POE::Component::Server::Ident->spawn ( Alias => 'Ident-Server', BindAddr => '127.0.0.1', BindPort => 0, Multiple => 0 );

print "ok 1\n";

POE::Session->create
  ( inline_states =>
      { _start => \&client_start,
	_stop  => \&client_stop,
	_sock_up => \&_sock_up,
	_sock_failed => \&_sock_failed,
	_parseline => \&_parseline,
	identd_request => \&identd_request,
      },
    heap => { Port1 => 12345, Port2 => 123, UserID => 'bingos', Identd => $identd },
  );

POE::Kernel->run();
exit;

sub client_start {
  my ($kernel,$heap) = @_[KERNEL,HEAP];

  my ($remoteport,undef) = unpack_sockaddr_in( $heap->{Identd}->getsockname() );

  $kernel->call ( 'Ident-Server' => 'register' );

  $heap->{'SocketFactory'} = POE::Wheel::SocketFactory->new (
				RemoteAddress => '127.0.0.1',
				RemotePort => $remoteport,
				SuccessEvent => '_sock_up',
                                FailureEvent => '_sock_failed',
				BindAddress => '127.0.0.1'
                             );
}

sub client_stop {

  foreach ( @tests ) {
	print "$_\n";
  }

}

sub _sock_up {
  my ($kernel,$heap,$socket) = @_[KERNEL,HEAP,ARG0];

  delete ( $heap->{'SocketFactory'} );

  $heap->{'socket'} = new POE::Wheel::ReadWrite
  (
        Handle => $socket,
        Driver => POE::Driver::SysRW->new(),
        Filter => POE::Filter::Line->new( Literal => "\x0D\x0A" ),
        InputEvent => '_parseline',
        ErrorEvent => '_sock_down',
   );

  $heap->{'socket'}->put($heap->{'Port1'} . ", " . $heap->{'Port2'});
}

sub _sock_failed {
  $_[KERNEL]->call ( 'Ident-Server' => 'shutdown' );
}

sub _sock_down {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  delete ( $heap->{'socket'} );
}

sub _parseline {
  my ($kernel,$heap,$input) = @_[KERNEL,HEAP,ARG0];

#  print STDERR "$input\n";
  if ( index ( $input, $heap->{'UserID'} ) != -1 ) {
	$tests[1] = "ok";
  }

  $kernel->post ( 'Ident-Server' => 'unregister' );
  $kernel->post ( 'Ident-Server' => 'shutdown' );
  delete ( $heap->{'socket'} );
}

sub identd_request {
  my ($kernel,$heap,$sender,$peeraddr,$first,$second) = @_[KERNEL,HEAP,SENDER,ARG0,ARG1,ARG2];

  $tests[0] = "ok";

  $kernel->call ( $sender => ident_server_reply => 'UNIX' => $heap->{'UserID'} );
}
