package Catalyst::Authentication::Store::Minimal;

use strict;
use warnings;

use Catalyst::Authentication::User::Hash;
use Scalar::Util qw( blessed );
use base qw/Class::Accessor::Fast/;

BEGIN {
    __PACKAGE__->mk_accessors(qw/userhash/);
}

sub new {
    my ( $class, $config, $app, $realm) = @_;

    bless { userhash => $config->{'users'} }, $class;
}

sub from_session {
	my ( $self, $c, $id ) = @_;

	return $id if ref $id;

	$self->find_user( { id => $id } );
}

## this is not necessarily a good example of what find_user can do, since all we do is   
## look up with the id anyway.  find_user can be used to locate a user based on other 
## combinations of data.  See C::P::Authentication::Store::DBIx::Class for a better example
sub find_user {
    my ( $self, $userinfo, $c ) = @_;

    my $id = $userinfo->{'id'};
    
    $id ||= $userinfo->{'username'};
    
    return unless exists $self->userhash->{$id};

    my $user = $self->userhash->{$id};

    #print STDERR "FOO1! " . ref($user) . " - ". Scalar::Util::blessed($user) . "\n";

    if ( ref($user) eq "HASH") {
        $user->{id} ||= $id;
        return bless $user, "Catalyst::Authentication::User::Hash";
    } elsif ( ref($user) && blessed($user) && $user->isa('Catalyst::Authentication::User::Hash')) {
        return $user;
    } else {
        Catalyst::Exception->throw( "The user '$id' must be a hash reference or an " .
                "object of class Catalyst::Authentication::User::Hash");
    }
    return $user;
}

sub user_supports {
    my $self = shift;

    # choose a random user
    scalar keys %{ $self->userhash };
    ( undef, my $user ) = each %{ $self->userhash };

    $user->supports(@_);
}

## Backwards compatibility
#
# This is a backwards compatible routine.  get_user is specifically for loading a user by it's unique id
# find_user is capable of doing the same by simply passing { id => $id }  
# no new code should be written using get_user as it is deprecated.
sub get_user {
    my ( $self, $id ) = @_;
    $self->find_user({id => $id});
}

## backwards compatibility
sub setup {
    my $c = shift;

    ### If a user does 'use Catalyst qw/Authentication::Store::Minimal/'
    ### he will be proxied on to this setup routine (and only then --
    ### non plugins should NOT have their setup routine invoked!)
    ### Beware what we pass to the 'new' routine; it wants
    ### a config has with a top level key 'users'. New style
    ### configs do not have this, and split by realms. If we
    ### blindly pass this to new, we will 1) overwrite what we
    ### already passed and 2) make ->userhash undefined, which
    ### leads to:
    ###  Can't use an undefined value as a HASH reference at
    ###  lib/Catalyst/Authentication/Store/Minimal.pm line 38.
    ###
    ### So only do this compatibility call if:
    ### 1) we have a {users} config directive 
    ###
    ### Ideally we could also check for:
    ### 2) we don't already have a ->userhash
    ### however, that's an attribute of an object we can't 
    ### access =/ --kane
    
    my $cfg = $c->config->{'Plugin::Authentication'}->{users}
                ? $c->config->{'Plugin::Authentication'}
                : undef;

    $c->default_auth_store( __PACKAGE__->new( $cfg, $c ) ) if $cfg;
    
	$c->NEXT::setup(@_);
}

__PACKAGE__;

__END__

=pod

=head1 NAME

Catalyst::Authentication::Store::Minimal - Minimal authentication store

=head1 SYNOPSIS

    # you probably just want Store::Minimal under most cases,
    # but if you insist you can instantiate your own store:

    use Catalyst::Authentication::Store::Minimal;

    use Catalyst qw/
        Authentication
    /;

    __PACKAGE__->config->{'Plugin::Authentication'} = 
                    {  
                        default_realm => 'members',
                        realms => {
                            members => {
                                credential => {
                                    class => 'Password',
                                    password_field => 'password',
                                    password_type => 'clear'
                                },
                                store => {
                                    class => 'Minimal',
                	                users = {
                	                    bob => {
                	                        password => "s00p3r",                	                    
                	                        editor => 'yes',
                	                        roles => [qw/edit delete/],
                	                    },
                	                    william => {
                	                        password => "s3cr3t",
                	                        roles => [qw/comment/],
                	                    }
                	                }	                
                	            }
                	        }
                    	}
                    };

    
=head1 DESCRIPTION

This authentication store lets you create a very quick and dirty user
database in your application's config hash.

You will need to include the Authentication plugin, and at least one Credential
plugin to use this Store. Credential::Password is reccommended.

It's purpose is mainly for testing, and it should probably be replaced by a
more "serious" store for production.

The hash in the config, as well as the user objects/hashes are freely mutable
at runtime.

=head1 CONFIGURATION

=over 4

=item class 

The classname used for the store. This is part of
L<Catalyst::Plugin::Authentication> and is the method by which
Catalyst::Authentication::Store::Minimal is loaded as the
user store. For this module to be used, this must be set to
'Minimal'.

=item users

This is a simple hash of users, the keys are the usenames, and the values are
hashrefs containing a password key/value pair, and optionally, a roles/list 
of role-names pair. If using roles, you will also need to add the 
Authorization::Roles plugin.

See the SYNOPSIS for an example.

=back

=head1 METHODS

There are no publicly exported routines in the Minimal store (or indeed in
most authentication stores)  However, below is a description of the routines 
required by L<Catalyst::Plugin::Authentication> for all authentication stores.

=head2 new( $config, $app, $realm )

Constructs a new store object, which uses the user element of the supplied config 
hash ref as it's backing structure.

=head2 find_user( $authinfo, $c ) 

Keys the hash by the 'id' or 'username' element in the authinfo hash and returns the user.

... documentation fairy stopped here. ...

If the return value is unblessed it will be blessed as
L<Catalyst::Authentication::User::Hash>.

=head2 from_session( $id )

Delegates to C<get_user>.

=head2 user_supports( )

Chooses a random user from the hash and delegates to it.

=head2 get_user( )

=head2 setup( )

=cut


