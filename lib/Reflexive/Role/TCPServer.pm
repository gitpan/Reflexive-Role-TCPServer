package Reflexive::Role::TCPServer;
BEGIN {
  $Reflexive::Role::TCPServer::VERSION = '1.110100';
}

#ABSTRACT: Provides a consumable Reflex-based multiplexing TCP server behavior

use Reflex::Role;
use Moose::Util::TypeConstraints;
use MooseX::Params::Validate;
use MooseX::Types::Moose(':all');
use MooseX::Types::Structured(':all');
use IO::Socket::INET;
use POE::Filter::Stream;
use Reflexive::Stream::Filtering;
use Reflex::Callbacks('cb_method');
use Try::Tiny;



attribute_parameter 'input_filter_class' => 'POE::Filter::Stream';


parameter input_filter_args =>
(
    isa => HashRef,
    default => sub { {} },
);


attribute_parameter 'output_filter_class' => 'POE::Filter::Stream';


parameter output_filter_args =>
(
    isa => HashRef,
    default => sub { {} },
);

role
{
    my $p = shift;
    my $input_filter_class = $p->input_filter_class;
    my $output_filter_class = $p->output_filter_class;
    my %input_filter_args = %{$p->input_filter_args};
    my %output_filter_args = %{$p->output_filter_args};


    requires qw/on_socket_data/;


    has port =>
    (
        is => 'ro',
        isa => Int,
        default => 5000,
        writer => '_set_port',
    );


    has host =>
    (
        is => 'ro',
        isa => Str,
        default => '0.0.0.0',
        writer => '_set_host',
    );


    has listener =>
    (
        is          => 'ro',
        isa         => FileHandle,
        lazy        => 1,
        clearer     => 'clear_listener',
        predicate   => 'has_listener',
        builder     => '_build_listener',
    );


    has sockets =>
    (
        is      => 'ro',
        isa     => HashRef,
        traits  => ['Hash'],
        default => sub { {} },
        clearer => '_clear_sockets',
        handles =>
        {
            '_set_socket'       => 'set',
            '_delete_socket'    => 'delete',
            '_count_sockets'    => 'count',
            '_all_sockets'      => 'values',
        }
    );

    # unfortunate Moose bug that attribute delegates are not instantiated
    # in a role until composition time. The workaround is to define stubs
    # in the role and when the attribute fully instantiated, the delegates
    # are installed and take over

    sub _set_socket {}
    sub _delete_socket {}
    sub _count_sockets {}
    sub _clear_sockets {}
    sub _all_sockets {}

    with 'Reflex::Role::Accepting' =>
    {
        listener      => 'listener',
        method_pause  => 'pause_listening',
        method_resume => 'resume_listening',
        method_stop   => 'stop_listening',
    };

    with 'Reflexive::Role::Collective' =>
    {
        stored_constraint => role_type('Reflex::Role::Collectible'),
        watched_events =>
        [
            [ stopped   => ['emit_socket_stop',     'socket_stop' ] ],
            [ error     => ['emit_socket_error',    'socket_error'] ],
            [ data      => ['emit_socket_data',     'socket_data' ] ],
        ],
        method_remember         => 'store_socket',
        method_forget           => 'remove_socket',
        method_clear_objects    => '_clear_sockets',
        method_count_objects    => '_count_sockets',
        method_add_object       => '_set_socket',
        method_del_object       => '_delete_socket',
    };


    method _build_listener => sub
    {
        my $self = shift;
        my $listener = IO::Socket::INET->new
        (
            Listen      => 5,
            LocalAddr   => $self->host,
            LocalPort   => $self->port,
            Proto       => 'tcp',
        );

        unless($listener)
        {
            Carp::confess "Unable to bind to ${\$self->host}:${\$self->port}";
        }

        return $listener;
    };


    method _build_socket => sub
    {
        my ($self, $handle) = pos_validated_list
        (
            \@_,
            { does => 'Reflexive::Role::TCPServer' },
            { isa => FileHandle },
        );

        return Reflexive::Stream::Filtering->new
        (
            handle => $handle,
            input_filter => $input_filter_class->new(%input_filter_args),
            output_filter => $output_filter_class->new(%output_filter_args),
        );

    };


    method try_listener_build => sub
    {
        my $self = shift;

        try
        {
            $self->listener();
        }
        catch
        {
            $self->on_listener_error
            (
                {
                    errstr => "$!",
                    errnum => ($! + 0),
                    errfun => 'bind',
                }
            );
        }
    };


    method BUILD => sub { };

    # slight timing bug with regard to Reflex::Role::Readable
    # we need to make sure the listening socket is created before
    # it is fed to the underlying POE mechanism hence why before
    # is used instead of after

    before BUILD => sub
    {
        my $self = shift;
        # start listening
        $self->try_listener_build();
    };

    after BUILD => sub
    {
        my $self = shift;
        $self->watch
        (
            $self,
            'socket_stop'   => cb_method($self, 'on_socket_stop'),
            'socket_error'  => cb_method($self, 'on_socket_error'),
            'socket_data'   => cb_method($self, 'on_socket_data'),
        );
    };



    method on_listener_accept => sub
    {
        my ($self, $args) = pos_validated_list
        (
            \@_,
            { does => 'Reflexive::Role::TCPServer' },
            { isa => Dict[peer => Str, socket => FileHandle] },
        );

        $self->store_socket($self->_build_socket($args->{socket}));

    };


    method on_listener_error => sub
    {
        my ($self, $args) = pos_validated_list
        (
            \@_,
            { does => 'Reflexive::Role::TCPServer' },
            {
                isa => Dict
                [
                    errnum => Num,
                    errstr => Str,
                    errfun => Str
                ]
            },
        );

        die "Failed to ${\$args->{errfun}}. " .
            "Error Code: ${\$args->{errnum}} " .
            "Error Message: ${\$args->{errstr}}";
    };


    method on_socket_stop => sub
    {
        my ($self, $args) = pos_validated_list
        (
            \@_,
            { does => 'Reflexive::Role::TCPServer' },
            { args => Dict[_sender => Object] },
        );

        # This is a solid assumption that the socket will be the source of the
        # event and therefore it will be first in the Reflex _sender stack

        $self->remove_socket($args->{_sender}->get_first_emitter());
    };


    method on_socket_error => sub
    {
        my ($self, $args) = pos_validated_list
        (
            \@_,
            { does => 'Reflexive::Role::TCPServer' },
            {
                isa => Dict
                [
                    _sender => Object,
                    errnum => Num,
                    errstr => Str,
                    errfun => Str
                ]
            },
        );

        # This is a solid assumption that the socket will be the source of the
        # error and therefore it will be first in the Reflex _sender stack

        $self->remove_socket($args->{_sender}->get_first_emitter());
    };


    method shutdown => sub
    {
        my $self = shift;
        $self->stop_listening();
        $_->stopped() for $self->_all_sockets();
    }
};

1;


=pod

=head1 NAME

Reflexive::Role::TCPServer - Provides a consumable Reflex-based multiplexing TCP server behavior

=head1 VERSION

version 1.110100

=head1 SYNOPSIS

    {
        package MyTCPServer;
        use Moose;
        use MooseX::Types::Moose(':all');
        use MooseX::Types::Structured(':all');
        use MooseX::Params::Validate;

        extends 'Reflex::Base';

        sub on_socket_data
        {
            my ($self, $args) = pos_validated_list
            (
                \@_,
                { isa => 'MyTCPServer' },
                {
                    isa => Dict
                    [
                        data => Any,
                        _sender => Object
                    ]
                },
            );
            my $data = $args->{data};
            my $socket = $args->{_sender}->get_first_emitter();
            warn "Received data ($data) from socket ($socket)";
            chomp($data);
            # look at Reflex::Role::Streaming for what methods are available
            $socket->put(reverse($data)."\n");
        }

        with 'Reflexive::Role::TCPServer';
    }

    my $server = MyTCPServer->new();
    $server->run_all();

=head1 DESCRIPTION

Reflexive::Role::TCPServer provides a multiplexing TCP server behavior for
consuming classes. It does this by being an amalgamation of other Reflex and
Reflexive roles such as L<Reflex::Role::Accepting> and
L<Reflexive::Role::Collective>. The only required method to be implemented by
the consumer is L</on_socket_data> which is called when sockets receive data.

See the eg directory in the shipped distribution for an example that is more
detailed than the synopsis.

=head1 ROLE_PARAMETERS

=head2 input_filter_class

This is the name of the class to use when constructing an input filter for each
socket that is accepted. It defaults to L<POE::Filter::Stream>.

Please see L<Reflexive::Stream::Filtering> for more information on how
filtering occurs on data.

=head2 input_filter_args

If the input filter class takes any arguments during construction, put them
here as a HashRef

=head2 output_filter_class

This is the name of the class to use when constructing an output filter for each
socket that is accepted. It defaults to L<POE::Filter::Stream>.

Please see L<Reflexive::Stream::Filtering> for more information on how
filtering occurs on data.

=head2 output_filter_args

If the output filter class takes any arguments during construction, put them
here as a HashRef

=head1 ROLE_REQUIRES

=head2 on_socket_data

    Dict[data => Any, _sender => Object]

This role requires the method on_socket_data to be implemented in the consuming
class prior to application. The inbound, filtered data will be available in the
HashRef under the key 'data'. The socket that generated the event will be
available via L<Reflex::Sender/get_first_emitter> on the _sender object.

=head1 PUBLIC_ATTRIBUTES

=head2 port

    is: ro, isa: Int, default: 5000, writer: _set_port

port holds the particular TCP port number to use when listening for
connections. It defaults to 5000 for no real particular reason, other than
to make it easier to use this role in the PSGI space.

=head2 host

    is: ro, isa: Str, default: '0.0.0.0', writer: _set_host

host holds the address to use when setting up the listening socket. It defaults
to 0.0.0.0 (which means all available interfaces/addresses).

=head1 PROTECTED_ATTRIBUTES

=head2 listener

    is: ro, isa: FileHandle, lazy: 1
    clearer:    clear_listener
    predicate:  has_listener
    builder:    _build_listener

listener holds the listening socket from which to accept connections. Ideally,
this attribute shouldn't be touched in consuming classes

=head2 sockets

    is: ro, isa: HashRef, traits: Hash
    clearer: _clear_sockets
    handles:
            '_set_socket'       => 'set',
            '_delete_socket'    => 'delete',
            '_count_sockets'    => 'count',
            '_all_sockets'      => 'values',

sockets stores the complete, accepted connections from clients.

sockets is really only for low-level access and the facilities from the
consumed L<Reflexive::Role::Collective> should be used to store/remove clients.

=head1 PUBLIC_METHODS

=head2 try_listener_build

try_listener_build is the method called when the object is first instantiated
to attempt to bind a listening socket. It wraps construction of the
L</listener> attribute inside a try/catch block. If it fails the
L</on_listener_error> callback is fired to allow for retrying the binding.

=head2 shutdown

shutdown will stop the listening socket forcibly stop all active sockets.

This will allow the event loop to terminate.

=head1 PROTECTED_METHODS

=head2 _build_listener

_build_listener takes the L</host> and L</port> attributes and builds a
listening socket using L<IO::Socket::INET>. If it is unable to bind to the
host/port combination, it will confess.

=head2 _build_socket

    (FileHandle)

_build_socket is called when the listener_accept event fires. The raw socket,
and the filters constructed from the L</input_filter_class> and
L</output_filter_class> parameters are passed to the constructor for
L<Reflexive::Stream::Filtering> and returned.

=head2 BUILD

BUILD is advised in a couple of different ways to ensure proper operation:

1) before BUILD is used to attempt to build the listener socket prior to
L<Reflex::Role::Readable> attempts to use the socket. This allows for the
capture of exceptions on binding if they occur.

2) after BUILD is used to watch the events that this role emits.

=head2 on_listener_accept

    (Dict[peer => Str, socket => FileHandle])

on_listener_accept is the callback method called when a socket connection has
been accepted. It calls L</_build_socket> and stores the result using
L<Reflexive::Role::Collective/remember> which is named "store_socket" in this
role.

=head2 on_listener_error

    (Dict[errnum => Num, errstr => Str, errfun => Str])

on_listener_error is the callback called when there is an error on the
listening socket.

=head2 on_socket_stop

    (Dict[_sender => Object])

on_socket_stop is the callback method fired when sockets close. It calls
L<Reflexive::Role::Collective/forget>, which is named "remove_socket" in this
role, to no longer store the socket. The socket that sent the event will be
the first emitter.

=head2 on_socket_error

    (Dict[_sender => Object, errnum => Num, errstr => Str, errfun => Str])

on_socket_error is the callback fired when a socket encounters an error. The
socket that sent the event will be the first emitter. This method merely
unstores the socket.

=head1 AUTHOR

Nicholas R. Perez <nperez@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2010 by Nicholas R. Perez <nperez@cpan.org>.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut


__END__
