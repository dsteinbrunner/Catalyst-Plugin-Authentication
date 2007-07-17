#!/usr/bin/perl

package Catalyst::Plugin::Authentication;

use base qw/Class::Accessor::Fast Class::Data::Inheritable/;

BEGIN {
    __PACKAGE__->mk_accessors(qw/_user/);
    __PACKAGE__->mk_classdata($_) for qw/_auth_realms/;
}

use strict;
use warnings;

use Tie::RefHash;
use Class::Inspector;

# this optimization breaks under Template::Toolkit
# use user_exists instead
#BEGIN {
#	require constant;
#	constant->import(have_want => eval { require Want });
#}

our $VERSION = "0.10";

sub set_authenticated {
    my ( $c, $user, $realmname ) = @_;

    $c->user($user);
    $c->request->{user} = $user;    # compatibility kludge

    if (!$realmname) {
        $realmname = 'default';
    }
    
    if (    $c->isa("Catalyst::Plugin::Session")
        and $c->config->{authentication}{use_session}
        and $user->supports("session") )
    {
        $c->save_user_in_session($realmname, $user);
    }
    $user->_set_auth_realm($realmname);
    
    $c->NEXT::set_authenticated($user, $realmname);
}

sub _should_save_user_in_session {
    my ( $c, $user ) = @_;

    $c->_auth_sessions_supported
    and $c->config->{authentication}{use_session}
    and $user->supports("session");
}

sub _should_load_user_from_session {
    my ( $c, $user ) = @_;

    $c->_auth_sessions_supported
    and $c->config->{authentication}{use_session}
    and $c->session_is_valid;
}

sub _auth_sessions_supported {
    my $c = shift;
    $c->isa("Catalyst::Plugin::Session");
}

sub user {
    my $c = shift;

    if (@_) {
        return $c->_user(@_);
    }

    if ( defined(my $user = $c->_user) ) {
        return $user;
    } else {
        return $c->auth_restore_user;
    }
}

# change this to allow specification of a realm - to verify the user is part of that realm
# in addition to verifying that they exist. 
sub user_exists {
	my $c = shift;
	return defined($c->_user) || defined($c->_user_in_session);
}


sub save_user_in_session {
    my ( $c, $realmname, $user ) = @_;

    $c->session->{__user_realm} = $realmname;
    
    # we want to ask the backend for a user prepared for the session.
    # but older modules split this functionality between the user and the
    # backend.  We try the store first.  If not, we use the old method.
    my $realm = $c->get_auth_realm($realmname);
    if ($realm->{'store'}->can('for_session')) {
        $c->session->{__user} = $realm->{'store'}->for_session($c, $user);
    } else {
        $c->session->{__user} = $user->for_session;
    }
}

sub logout {
    my $c = shift;

    $c->user(undef);

    if (
        $c->isa("Catalyst::Plugin::Session")
        and $c->config->{authentication}{use_session}
        and $c->session_is_valid
    ) {
        delete @{ $c->session }{qw/__user __user_realm/};
    }
    
    $c->NEXT::logout(@_);
}

sub find_user {
    my ( $c, $userinfo, $realmname ) = @_;
    
    $realmname ||= 'default';
    my $realm = $c->get_auth_realm($realmname);
    if ( $realm->{'store'} ) {
        return $realm->{'store'}->find_user($userinfo, $c);
    } else {
        $c->log->debug('find_user: unable to locate a store matching the requested realm');
    }
}


sub _user_in_session {
    my $c = shift;

    return unless $c->_should_load_user_from_session;

    return $c->session->{__user};
}

sub _store_in_session {
    my $c = shift;
    
    # we don't need verification, it's only called if _user_in_session returned something useful

    return $c->session->{__user_store};
}

sub auth_restore_user {
    my ( $c, $frozen_user, $realmname ) = @_;

    $frozen_user ||= $c->_user_in_session;
    return unless defined($frozen_user);

    $realmname  ||= $c->session->{__user_realm};
    return unless $realmname; # FIXME die unless? This is an internal inconsistency

    my $realm = $c->get_auth_realm($realmname);
    $c->_user( my $user = $realm->{'store'}->from_session( $c, $frozen_user ) );
    
    # this sets the realm the user originated in.
    $user->_set_auth_realm($realmname);
    return $user;

}

# we can't actually do our setup in setup because the model has not yet been loaded.  
# So we have to trigger off of setup_finished.  :-(
sub setup {
    my $c = shift;

    $c->_authentication_initialize();
    $c->NEXT::setup(@_);
}

## the actual initialization routine. whee.
sub _authentication_initialize {
    my $c = shift;

    if ($c->_auth_realms) { return };
    
    my $cfg = $c->config->{'authentication'} || {};

    %$cfg = (
        use_session => 1,
        %$cfg,
    );

    my $realmhash = {};
    $c->_auth_realms($realmhash);
    
    ## BACKWARDS COMPATIBILITY - if realm is not defined - then we are probably dealing
    ## with an old-school config.  The only caveat here is that we must add a classname 
    if (exists($cfg->{'realms'})) {
        
        foreach my $realm (keys %{$cfg->{'realms'}}) {
            $c->setup_auth_realm($realm, $cfg->{'realms'}{$realm});
        }

        #  if we have a 'default-realm' in the config hash and we don't already 
        # have a realm called 'default', we point default at the realm specified
        if (exists($cfg->{'default_realm'}) && !$c->get_auth_realm('default')) {
            $c->set_default_auth_realm($cfg->{'default_realm'});
        }
    } else {
        foreach my $storename (keys %{$cfg->{'stores'}}) {
            my $realmcfg = {
                store => $cfg->{'stores'}{$storename},
            };
            $c->setup_auth_realm($storename, $realmcfg);
        }
    }
    
}


# set up realmname.
sub setup_auth_realm {
    my ($app, $realmname, $config) = @_;
    
    $app->log->debug("Setting up $realmname");
    if (!exists($config->{'store'}{'class'})) {
        Carp::croak "Couldn't setup the authentication realm named '$realmname', no class defined";
    } 
        
    # use the 
    my $storeclass = $config->{'store'}{'class'};
    
    ## follow catalyst class naming - a + prefix means a fully qualified class, otherwise it's
    ## taken to mean C::P::A::Store::(specifiedclass)::Backend
    if ($storeclass !~ /^\+(.*)$/ ) {
        $storeclass = "Catalyst::Plugin::Authentication::Store::${storeclass}::Backend";
    } else {
        $storeclass = $1;
    }
    

    # a little niceness - since most systems seem to use the password credential class, 
    # if no credential class is specified we use password.
    $config->{credential}{class} ||= "Catalyst::Plugin::Authentication::Credential::Password";

    my $credentialclass = $config->{'credential'}{'class'};
    
    ## follow catalyst class naming - a + prefix means a fully qualified class, otherwise it's
    ## taken to mean C::P::A::Credential::(specifiedclass)
    if ($credentialclass !~ /^\+(.*)$/ ) {
        $credentialclass = "Catalyst::Plugin::Authentication::Credential::${credentialclass}";
    } else {
        $credentialclass = $1;
    }
    
    # if we made it here - we have what we need to load the classes;
    Catalyst::Utils::ensure_class_loaded( $credentialclass );
    Catalyst::Utils::ensure_class_loaded( $storeclass );
    
    # BACKWARDS COMPATIBILITY - if the store class does not define find_user, we define it in terms 
    # of get_user and add it to the class.  this is because the auth routines use find_user, 
    # and rely on it being present. (this avoids per-call checks)
    if (!$storeclass->can('find_user')) {
        no strict 'refs';
        *{"${storeclass}::find_user"} = sub {
                                                my ($self, $info) = @_;
                                                my @rest = @{$info->{rest}} if exists($info->{rest});
                                                $self->get_user($info->{id}, @rest);
                                            };
    }
    
    $app->auth_realms->{$realmname}{'store'} = $storeclass->new($config->{'store'}, $app);
    if ($credentialclass->can('new')) {
        $app->auth_realms->{$realmname}{'credential'} = $credentialclass->new($config->{'credential'}, $app);
    } else {
        # if the credential class is not actually a class - has no 'new' operator, we wrap it, 
        # once again - to allow our code to be simple at runtime and allow non-OO packages to function.
        my $wrapperclass = 'Catalyst::Plugin::Authentication::Credential::Wrapper';
        Catalyst::Utils::ensure_class_loaded( $wrapperclass );
        $app->auth_realms->{$realmname}{'credential'} = $wrapperclass->new($config->{'credential'}, $app);
    }
}

sub auth_realms {
    my $self = shift;
    return($self->_auth_realms);
}

sub get_auth_realm {
    my ($app, $realmname) = @_;
    return $app->auth_realms->{$realmname};
}

sub set_default_auth_realm {
    my ($app, $realmname) = @_;
    
    if (exists($app->auth_realms->{$realmname})) {
        $app->auth_realms->{'default'} = $app->auth_realms->{$realmname};
    }
    return $app->get_auth_realm('default');
}

sub authenticate {
    my ($app, $userinfo, $realmname) = @_;
    
    if (!$realmname) {
        $realmname = 'default';
    }
        
    my $realm = $app->get_auth_realm($realmname);
    
    if ($realm && exists($realm->{'credential'})) {
        my $user = $realm->{'credential'}->authenticate($app, $realm->{store}, $userinfo);
        if ($user) {
            $app->set_authenticated($user, $realmname);
            return $user;
        }
    } else {
        $app->log->debug("The realm requested, '$realmname' does not exist," .
                         " or there is no credential associated with it.")
    }
    return undef;
}

## BACKWARDS COMPATIBILITY  -- Warning:  Here be monsters!
#
# What follows are backwards compatibility routines - for use with Stores and Credentials
# that have not been updated to work with C::P::Authentication v0.10.  
# These are here so as to not break people's existing installations, but will go away
# in a future version.
#
# The old style of configuration only supports a single store, as each store module
# sets itself as the default store upon being loaded.  This is the only supported 
# 'compatibility' mode.  
#

sub get_user {
    my ( $c, $uid, @rest ) = @_;

    return $c->find_user( {'id' => $uid, 'rest'=>\@rest }, 'default' );
}

##
## this should only be called when using old-style authentication plugins.  IF this gets
## called in a new-style config - it will OVERWRITE the store of your default realm.  Don't do it.
## also - this is a partial setup - because no credential is instantiated... in other words it ONLY
## works with old-style auth plugins and C::P::Authentication in compatibility mode.  Trying to combine
## this with a realm-type config will probably crash your app.
sub default_auth_store {
    my $self = shift;

    if ( my $new = shift ) {
        $self->auth_realms->{'default'}{'store'} = $new;
        my $storeclass = ref($new);
        
        # BACKWARDS COMPATIBILITY - if the store class does not define find_user, we define it in terms 
        # of get_user and add it to the class.  this is because the auth routines use find_user, 
        # and rely on it being present. (this avoids per-call checks)
        if (!$storeclass->can('find_user')) {
            no strict 'refs';
            *{"${storeclass}::find_user"} = sub {
                                                    my ($self, $info) = @_;
                                                    my @rest = @{$info->{rest}} if exists($info->{rest});
                                                    $self->get_user($info->{id}, @rest);
                                                };
        }
    }

    return $self->get_auth_realm('default')->{'store'};
}

## BACKWARDS COMPATIBILITY
## this only ever returns a hash containing 'default' - as that is the only
## supported mode of calling this.
sub auth_store_names {
    my $self = shift;

    my %hash = (  $self->get_auth_realm('default')->{'store'} => 'default' );
}

sub get_auth_store {
    my ( $self, $name ) = @_;
    
    if ($name ne 'default') {
        Carp::croak "get_auth_store called on non-default realm '$name'. Only default supported in compatibility mode";        
    } else {
        $self->default_auth_store();
    }
}

sub get_auth_store_name {
    my ( $self, $store ) = @_;
    return 'default';
}

# sub auth_stores is only used internally - here for completeness
sub auth_stores {
    my $self = shift;

    my %hash = ( 'default' => $self->get_auth_realm('default')->{'store'});
}






__PACKAGE__;

__END__

=pod

=head1 NAME

Catalyst::Plugin::Authentication - Infrastructure plugin for the Catalyst
authentication framework.

=head1 SYNOPSIS

    use Catalyst qw/
        Authentication
    /;

    # later on ...
    $c->authenticate({ username => 'myusername', password => 'mypassword' });
    my $age = $c->user->get('age');
    $c->logout;

=head1 DESCRIPTION

The authentication plugin provides generic user support. It is the basis 
for both authentication (checking the user is who they claim to be), and 
authorization (allowing the user to do what the system authorises them to do).

Using authentication is split into two parts. A Store is used to actually 
store the user information, and can store any amount of data related to 
the user. Multiple stores can be accessed from within one application. 
Credentials are used to verify users, using information from the store, 
given data from the frontend.

To implement authentication in a Catalyst application you need to add this 
module, plus at least one store and one credential module.

Authentication data can also be stored in a session, if the application 
is using the L<Catalyst::Plugin::Session> module.

=head1 INTRODUCTION

=head2 The Authentication/Authorization Process

Web applications typically need to identify a user - to tell the user apart
from other users. This is usually done in order to display private information
that is only that user's business, or to limit access to the application so
that only certain entities can access certain parts.

This process is split up into several steps. First you ask the user to identify
themselves. At this point you can't be sure that the user is really who they
claim to be.

Then the user tells you who they are, and backs this claim with some piece of
information that only the real user could give you. For example, a password is
a secret that is known to both the user and you. When the user tells you this
password you can assume they're in on the secret and can be trusted (ignore
identity theft for now). Checking the password, or any other proof is called
B<credential verification>.

By this time you know exactly who the user is - the user's identity is
B<authenticated>. This is where this module's job stops, and other plugins step
in. The next logical step is B<authorization>, the process of deciding what a
user is (or isn't) allowed to do. For example, say your users are split into
two main groups - regular users and administrators. You should verify that the
currently logged in user is indeed an administrator before performing the
actions of an administrative part of your application. One way to do this is
with role based access control.

=head2 The Components In This Framework

=head3 Realms

Configuration of the Catalyst::Plugin::Authentication framework is done in
terms of realms. In simplest terms, a realm is a pairing of a Credential
verifier and a User storage (Store) backend.

An application can have any number of Realms, each of which operates
independant of the others. Each realm has a name, which is used to identify it
as the target of an authentication request. This name can be anything, such as
'users' or 'members'. One realm must be defined as the default_realm, which is
used when no realm name is specified. More about this in the configuration
section.

=head3 Credential Verifiers

When user input is transferred to the L<Catalyst> application (typically via
form inputs) this authentication data then enters the authentication framework
through the $c->authenticate() routine. From there, it is passed to the
appropriate Credential verifier.

These plugins check the data, and ensure that it really proves the user is who
they claim to be.

=head3 Storage Backends

The authentication data also identify a user, and the Storage Backend modules
use this data to locate and return a standardized object-oriented
representation of a user.

When a user is retrieved from a store it is not necessarily authenticated.
Credential verifiers accept a set of authentication data and use this
information to retrieve the user from the store they are paired with.

=head3 The Core Plugin

This plugin on its own is the glue, providing realm configuration, session
integration, and other goodness for the other plugins.

=head3 Other Plugins

More layers of plugins can be stacked on top of the authentication code. For
example, L<Catalyst::Plugin::Session::PerUser> provides an abstraction of
browser sessions that is more persistent per users.
L<Catalyst::Plugin::Authorization::Roles> provides an accepted way to separate
and group users into categories, and then check which categories the current
user belongs to.

=head1 EXAMPLE

Let's say we were storing users in an simple perl hash. Users are
stored in that file, with a hashed password and some extra comments. Users are
verified by supplying a password which is matched with the file.

This means that our application will begin like this:

    package MyApp;

    use Catalyst qw/
        Authentication
    /;

    __PACKAGE__->config->{authentication} = 
                    {  
                        default_realm => 'members',
                        realms => {
                            members => {
                                credential => {
                                    class => 'Password'
                                },
                                store => {
                                    class => 'Minimal',
                	                users = {
                	                    bob => {
                	                        password => "s3cr3t",
                	                        editor => 'yes',
                	                        roles => [qw/edit delete/],
                	                    },
                	                    william => {
                	                        password => "s00p3r",
                	                        roles => [qw/comment/],
                	                    }
                	                }	                
                	            }
                	        }
                    	}
                    };
    

This tells the authentication plugin what realms are available, which credential
and store modules are used, and the configuration of each. 
    
With this code loaded, we can now attempt to authenticate users.  

To show an example of this, let's create an authentication controller:

    package MyApp::Controller::Auth;

    sub login : Local {
        my ( $self, $c ) = @_;

        if (    my $user = $c->req->param("user")
            and my $password = $c->req->param("password") )
        {
            if ( $c->authenticate( { username => $user, 
                                     password => $password } ) ) {
                $c->res->body( "hello " . $c->user->get("name") );
            } else {
                # login incorrect
            }
        }
        else {
            # invalid form input
        }
    }

This code should be very readable. If all the necessary fields are supplied,
call the L<Catalyst::Plugin::Authentication/authenticate> method in the
controller. If it succeeds the user is logged in.

The credential verifier will attempt to retrieve the user whose details match
the authentication information provided to $c->authenticate(). Once it fetches
the user the password is checked and if it matches the user will be
'authenticated' and C<< $c->user >> will contain the user object retrieved
from the store.

In the above case, the default realm is checked, but we could just as easily
check an alternate realm. If this were an admin login, for example, we could
authenticate on the admin realm by simply changing the $c->authenticate()
call:

    if ( $c->authenticate( { username => $user, 
                             password => $password }, 'admin' )l ) {
        $c->res->body( "hello " . $c->user->get("name") );
    } ...


Now suppose we want to restrict the ability to edit to a user with 'edit'
in it's roles list.  

The restricted action might look like this:

    sub edit : Local {
        my ( $self, $c ) = @_;

        $c->detach("unauthorized")
          unless $c->user_exists
          and $c->user->get('editor') == 'yes';

        # do something restricted here
    }

This is somewhat similar to role based access control.
L<Catalyst::Plugin::Authentication::Store::Minimal> treats the roles field as
an array of role names. Let's leverage this. Add the role authorization
plugin:

    use Catalyst qw/
        ...
        Authorization::Roles
    /;

    sub edit : Local {
        my ( $self, $c ) = @_;

        $c->detach("unauthorized") unless $c->check_roles("edit");

        # do something restricted here
    }

This is somewhat simpler and will work if you change your store, too, since the
role interface is consistent.

Let's say your app grew, and you now have 10000 users. It's no longer
efficient to maintain a hash of users, so you move this data to a database.
You can accomplish this simply by installing the DBIx::Class Store and
changing your config:

    __PACKAGE__->config->{authentication} = 
                    {  
                        default_realm => 'members',
                        realms => {
                            members => {
                                credential => {
                                    class => 'Password'
                                },
                                store => {
                                    class => 'DBIx::Class',
            	                    user_class => 'MyApp::Users',
            	                    role_column => 'roles'	                
            	                }
                	        }
                    	}
                    };

The authentication system works behind the scenes to load your data from the
new source. The rest of your application is completely unchanged.

=head1 METHODS

=over 4 


=item authenticate $userinfo, $realm

Attempts to authenticate the user using the information in $userinfo hash
reference using the realm $realm. $realm may be omitted, in which case the
default realm is checked.

=item user

Returns the currently logged in user or undef if there is none.

=item user_exists

Returns true if a user is logged in right now. The difference between
user_exists and user is that user_exists will return true if a user is logged
in, even if it has not been retrieved from the storage backend. If you only
need to know if the user is logged in, depending on the storage mechanism this
can be much more efficient.

=item logout

Logs the user out, Deletes the currently logged in user from C<user> and the session.

=item find_user( $userinfo, $realm )

Fetch a particular users details, matching the provided user info, from the realm 
specified in $realm.

=back

=head1 CONFIGURATION

=over 4

    # example
    __PACKAGE__->config->{authentication} = 
                {  
                    default_realm => 'members',
                    realms => {
                        members => {
                            credential => {
                                class => 'Password'
                            },
                            store => {
                                class => 'DBIx::Class',
        	                    user_class => 'MyApp::Users',
        	                    role_column => 'roles'	                
        	                }
            	        },
            	        admins => {
            	            credential => {
            	                class => 'Password'
            	            },
            	            store => {
            	                class => '+MyApp::Authentication::Store::NetAuth',
            	                authserver => '192.168.10.17'
            	            }
            	        }
            	        
                	}
                };

=item use_session

Whether or not to store the user's logged in state in the session, if the
application is also using the L<Catalyst::Plugin::Session> plugin. This 
value is set to true per default.

=item default_realm

This defines which realm should be used as when no realm is provided to methods
that require a realm such as authenticate or find_user.

=item realms

This contains the series of realm configurations you want to use for your app.
The only rule here is that there must be at least one.  A realm consists of a
name, which is used to reference the realm, a credential and a store.  

Each realm config contains two hashes, one called 'credential' and one called 
'store', each of which provide configuration details to the respective modules.
The contents of these hashes is specific to the module being used, with the 
exception of the 'class' element, which tells the core Authentication module the
classname to use for that entry.  

The 'class' element follows the standard Catalyst mechanism of class
specification. If a class is prefixed with a +, it is assumed to be a complete
class name. Otherwise it is considered to be a portion of the class name. For
credentials, the classname 'Password', for example, is expanded to
Catalyst::Plugin::Authentication::Credential::Password. For stores, the
classname 'storename' is expanded to:
Catalyst::Plugin::Authentication::Store::storename::Backend.


=back


=head1 INTERNAL METHODS

=over 4

=item set_authenticated $user

Marks a user as authenticated. Should be called from a
C<Catalyst::Plugin::Authentication::Credential> plugin after successful
authentication.

This involves setting C<user> and the internal data in C<session> if
L<Catalyst::Plugin::Session> is loaded.

=item auth_restore_user $user

Used to restore a user from the session, by C<user> only when it's actually
needed.

=item save_user_in_session $user

Used to save the user in a session.

=item prepare

Revives a user from the session object if there is one.

=item setup

Sets the default configuration parameters.

=item 

=back

=head1 SEE ALSO

This list might not be up to date.

=head2 User Storage Backends

L<Catalyst::Plugin::Authentication::Store::Minimal>,
L<Catalyst::Plugin::Authentication::Store::Htpasswd>,
L<Catalyst::Plugin::Authentication::Store::DBIC> (also works with Class::DBI).

=head2 Credential verification

L<Catalyst::Plugin::Authentication::Credential::Password>,
L<Catalyst::Plugin::Authentication::Credential::HTTP>,
L<Catalyst::Plugin::Authentication::Credential::TypeKey>

=head2 Authorization

L<Catalyst::Plugin::Authorization::ACL>,
L<Catalyst::Plugin::Authorization::Roles>

=head2 Internals Documentation

L<Catalyst::Plugin::Authentication::Store>

=head2 Misc

L<Catalyst::Plugin::Session>,
L<Catalyst::Plugin::Session::PerUser>

=head1 DON'T SEE ALSO

This module along with its sub plugins deprecate a great number of other
modules. These include L<Catalyst::Plugin::Authentication::Simple>,
L<Catalyst::Plugin::Authentication::CDBI>.

At the time of writing these plugins have not yet been replaced or updated, but
should be eventually: L<Catalyst::Plugin::Authentication::OpenID>,
L<Catalyst::Plugin::Authentication::LDAP>,
L<Catalyst::Plugin::Authentication::CDBI::Basic>,
L<Catalyst::Plugin::Authentication::Basic::Remote>.


=head1 COMPATIBILITY ROUTINES

=over 4

In version 0.10 of the L<Catalyst::Plugin::Authentication> plugin, the API
used changed. For app developers, this change is fairly minor, but for
Credential and Store authors, the changes are significant. The items below are
still present in the plugin, though using them is deprecated. They remain only
as a transition tool, for those sites which can not be upgraded to use the new
system due to local customizations, or use of Credential / store modules that
have not yet been updated.
 
=head1 METHODS FOR STORE MANAGEMENT

=over 4

=item default_auth_store

Return the store whose name is 'default'.

This is set to C<< $c->config->{authentication}{store} >> if that value exists,
or by using a Store plugin:

	use Catalyst qw/Authentication Authentication::Store::Minimal/;

Sets the default store to
L<Catalyst::Plugin::Authentication::Store::Minimal::Backend>.


=item get_auth_store $name

Return the store whose name is $name.

=item get_auth_store_name $store

Return the name of the store $store.

=item auth_stores

A hash keyed by name, with the stores registered in the app.

=item auth_store_names

A ref-hash keyed by store, which contains the names of the stores.

=item register_auth_stores %stores_by_name

Register stores into the application.

=back



=head1 AUTHORS

Yuval Kogman, C<nothingmuch@woobling.org>

Jess Robinson

David Kamholz

=head1 COPYRIGHT & LICENSE

        Copyright (c) 2005 the aforementioned authors. All rights
        reserved. This program is free software; you can redistribute
        it and/or modify it under the same terms as Perl itself.

=cut

