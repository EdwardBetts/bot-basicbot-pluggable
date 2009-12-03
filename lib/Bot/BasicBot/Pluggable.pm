package Bot::BasicBot::Pluggable;
use warnings;
use strict;

our $VERSION = '0.83';

use POE;
use Bot::BasicBot;
use Log::Log4perl;
use base qw( Bot::BasicBot );
use Data::Dumper;

$Data::Dumper::Terse  = 1;
$Data::Dumper::Indent = 0;

use Module::Pluggable
  sub_name    => '_available',
  search_path => 'Bot::BasicBot::Pluggable::Module',
  except      => 'Bot::BasicBot::Pluggable::Module::Base';
use Bot::BasicBot::Pluggable::Module;
use Bot::BasicBot::Pluggable::Store;
use File::Spec;
use Try::Tiny;

sub init {
    my $self = shift;

    Log::Log4perl->init({
	'log4perl.rootLogger'             => "TRACE, Screen",
	'log4perl.appender.Screen'        => 'Log::Log4perl::Appender::Screen',
	'log4perl.appender.Screen.stderr' => 0,
	'log4perl.appender.Screen.layout' => 'Log::Log4perl::Layout::SimpleLayout',
    });

    my $logger = Log::Log4perl->get_logger(ref $self);
    $logger->info('Starting initialization of ' . ref $self);
    
    if ( !$self->store ) {
	$logger->debug('Store not set, trying to load a store backend');
        my $store;
        for my $type (qw( DBI Deep Storable Memory )) {
            $store = try { 
		$logger->debug("Trying to load store backend $type");
		Bot::BasicBot::Pluggable::Store->new( { type => $type } ) 
		};
            if ($store) {
		$logger->info("Loaded store backend $type");
		last;
		}
        }
        if ( !UNIVERSAL::isa( $store, 'Bot::BasicBot::Pluggable::Store' ) ) {
            $logger->logdie( "Couldn't load any default store type" );
        }
        $self->store($store);
    }
    elsif ( !UNIVERSAL::isa( $self->store, "Bot::BasicBot::Pluggable::Store" ) )
    {
        $self->store( Bot::BasicBot::Pluggable::Store->new( $self->store ) );
    }
    return 1;
}

sub load {
    my $self   = shift;
    my $module = shift;

    my $logger = Log::Log4perl->get_logger(ref $self);
    # it's safe to die here, mostly this call is eval'd.
    $logger->logdie("Cannot load module with a name") unless $module;
    $logger->logdie("Module $module already loaded") if $self->handler($module);

    # This is possible a leeeetle bit evil.
    $logger->info("Loading module $module");
    my $file = "Bot/BasicBot/Pluggable/Module/$module.pm";
    $file = "./$module.pm"         if ( -e "./$module.pm" );
    $file = "./modules/$module.pm" if ( -e "./modules/$module.pm" );
    $logger->debug("Loading module $module from file $file");

    # force a reload of the file (in the event that we've already loaded it).
    no warnings 'redefine';
    delete $INC{$file};
    require $file;

    # Ok, it's very evil. Don't bother me, I'm working.

    my $m = "Bot::BasicBot::Pluggable::Module::$module"->new(
        Bot   => $self,
        Param => \@_
    );

    $logger->logdie("->new didn't return an object") unless ( $m and ref($m) );
    $logger->logdie(ref($m) . " isn't a $module")    unless ref($m) =~ /\Q$module/;

    $self->add_handler( $m, $module );

    return $m;
}

sub reload {
    my $self   = shift;
    my $module = shift;
    my $logger = Log::Log4perl->get_logger(ref $self);
    $logger->logdie("Cannot reload module with a name") unless $module;
    $self->remove_handler($module) if $self->handler($module);
    return $self->load($module);
}

sub unload {
    my $self   = shift;
    my $module = shift;
    my $logger = Log::Log4perl->get_logger(ref $self);
    $logger->logdie("Need name")  unless $module;
    $logger->logdie("Not loaded") unless $self->handler($module);
    $logger->info("Unloading module $module");
    $self->remove_handler($module);
}

sub module {
    my $self = shift;
    return $self->handler(@_);
}

sub modules {
    my $self = shift;
    return $self->handlers(@_);
}

sub available_modules {
    my $self = shift;
    my @local_modules =
      map { substr( ( File::Spec->splitpath($_) )[2], 0, -3 ) } 
        glob('./*.pm'),
        glob('./modules/*.pm');
    my @central_modules =
      map { s/^Bot::BasicBot::Pluggable::Module:://; $_ } $self->_available;
    return sort @local_modules, @central_modules;
}

# deprecated methods
sub handler {
    my ( $self, $name ) = @_;
    return $self->{handlers}{ lc($name) };
}

sub handlers {
    my $self = shift;
    my @keys = keys( %{ $self->{handlers} } );
    return @keys if wantarray;
    return \@keys;
}

sub add_handler {
    my ( $self, $handler, $name ) = @_;
    my $logger = Log::Log4perl->get_logger(ref $self);
    $logger->logdie("Need a name for adding a handler") unless $name;
    $logger->logdie("Can't load a handler with a duplicate name $name")
      if $self->{handlers}{ lc($name) };
    $self->{handlers}{ lc($name) } = $handler;
}

sub remove_handler {
    my ( $self, $name ) = @_;
    my $logger = Log::Log4perl->get_logger(ref $self);
    $logger->logdie("Need a name for removing a handler") unless $name;
    $logger->logdie("Hander $name not defined") unless $self->{handlers}{ lc($name) };
    $self->{handlers}{ lc($name) }->stop();
    delete $self->{handlers}{ lc($name) };
}

sub store {
    my $self = shift;
    if (@_) {
        $self->{store_object} = shift;
        return $self;
    }
    return $self->{store_object};
}

sub dispatch {
    my ($self,$method,@args)   = @_;
    my $logger = Log::Log4perl->get_logger(ref $self);

    $logger->info("Dispatching $method");
    for my $who ( $self->handlers ) {
	## Otherwise we would see tick every five seconds
	if ($method eq 'tick') {
    		$logger->trace("Trying to dispatch $method to $who") ;
	}
	else {
    		$logger->debug("Trying to dispatch $method to $who") ;
	}
	$logger->trace("... with " . Dumper(@args)) 
		if $logger->is_trace && @args;

        next unless $self->handler($who)->can($method);
        try {
	    $logger->trace("Dispatching $method to $who with " . Dumper(@args)) if $logger->is_trace;
            $self->handler($who)->$method(@args);
        }
        catch {
            $logger->warn($_);
        }
    }
    return undef;
}

sub help {
    my $self = shift;
    my $mess = shift;
    $mess->{body} =~ s/^help\s*//i;

    unless ( $mess->{body} ) {
        return
            "Ask me for help about: "
          . join( ", ", $self->handlers() )
          . " (say 'help <modulename>').";
    }
    elsif ( $mess->{body} eq 'modules' ) {
        return "These modules are available for loading: "
          . join( ", ", $self->available_modules );
    }
    else {
        if ( my $handler = $self->handler( $mess->{body} ) ) {
            try {
                return $handler->help($mess);
            }
            catch {
                return "Error calling help for handler $mess->{body}: $_";
            }
        }
        else {
            return "I don't know anything about '$mess->{body}'.";
        }
    }
}

#########################################################
# the following routines are lifted from Bot::BasicBot: #
#########################################################
sub tick {
    my $self = shift;
    $self->dispatch('tick');
    return 5;
}

sub said {
    my $self = shift;
    my ($mess) = @_;
    my $response;
    my $who;

    my $logger = Log::Log4perl->get_logger(ref $self);
    $logger->info('Dispatching said event');

    for my $priority ( 0 .. 3 ) {
        for my $handler ( $self->handlers ) {
            my $response;
	    $logger->debug("Trying to dispatch said to $handler on priority $priority");
            $logger->trace('... with arguments ' . Dumper($mess)) if $logger->is_trace and $mess;
            try {
                $response = $self->handler($handler)->said( $mess, $priority );
            }
            catch {
                $logger->warn($_);
            };
            if ( $priority and $response ) {
		$logger->debug("Response by $handler on $priority");
		$logger->trace('Response is ' . Dumper($response)) if $logger->is_trace;
		return if $response eq '1';
                $self->reply( $mess, $response );
                return;
            }
        }
    }
    return undef;
}

sub reply {
    my ( $self, $mess, @other ) = @_;
    $self->dispatch( 'replied', {%$mess}, @other );
    if ( $mess->{reply_hook} ) {
        return $mess->{reply_hook}->( $mess, @other );
    }
    else {
        return $self->SUPER::reply( $mess, @other );
    }
}

sub emoted {
    my $self = shift;
    my $mess = shift;
    my $response;
    my $who;
    for my $priority ( 0 .. 3 ) {
        for ( $self->handlers ) {
            $who = $_;
            try {
                my $response = $self->handler($who)->emoted( $mess, $priority );
                $self->reply( $mess, $response );
            }
            catch {
                $self->reply( $mess, "Error calling emoted() for $who: $_" );
            }
        }
    }
    return undef;
}

BEGIN {
    my @dispatchable_events = (
        qw/
          connected chanjoin chanpart userquit nick_change
          topic kicked
          /
    );
    no strict 'refs';
    for my $event (@dispatchable_events) {
        *$event = sub {
            shift->dispatch( $event, @_ );
        };
    }
}

1;    # sigh.

__END__

=head1 NAME

Bot::BasicBot::Pluggable - extended simple IRC bot for pluggable modules

=head1 SYNOPSIS

=head2 Creating the bot module

  # with all defaults.
  my $bot = Bot::BasicBot->new();

  # with useful options. pass any option
  # that's valid for Bot::BasicBot.
  my $bot = Bot::BasicBot::Pluggable->new(
  
                      channels => ["#bottest"],
                      server   => "irc.example.com",
                      port     => "6667",

                      nick     => "pluggabot",
                      altnicks => ["pbot", "pluggable"],
                      username => "bot",
                      name     => "Yet Another Pluggable Bot",

                      ignore_list => [qw(hitherto blech muttley)],

                );

=head2 Running the bot (simple)

There's a shell script installed to run the bot.

  $ bot-basicbot-pluggable --nick MyBot --server irc.perl.org

Then connect to the IRC server, /query the bot, and set a password. See
L<Bot::BasicBot::Pluggable::Module::Auth> for further details.

=head2 Running the bot (advanced)

There are two useful ways to create a Pluggable bot. The simple way is:

  # Load some useful modules.
  my $infobot_module = $bot->load("Infobot");
  my $google_module  = $bot->load("Google");
  my $seen_module    = $bot->load("Seen");

  # Set the Google key (see http://www.google.com/apis/).
  $google_module->set("google_key", "some google key");

  $bot->run();

The above lets you run a bot with a few modules, but not change those modules
during the run of the bot. The complex, but more flexible, way is as follows:

  # Load the Loader module.
  $bot->load('Loader');

  # run the bot.
  $bot->run();

This is simpler but needs further setup once the bot is joined to a server. The
Loader module lets you talk to the bot in-channel and tell it to load and unload
other modules. The first one you'll want to load is the 'Auth' module, so that
other people can't load and unload modules without permission. Then you'll need
to log in as an admin and change the default password, per the following /query:

  !load Auth
  !auth admin julia
  !password julia new_password
  !auth admin new_password

Once you've done this, your bot is safe from other IRC users, and you can tell
it to load and unload other installed modules at any time. Further information
on module loading is in L<Bot::BasicBot::Pluggable::Module::Loader>.

  !load Seen
  !load Google
  !load Join

The Join module lets you tell the bot to join and leave channels:

  <botname>, join #mychannel
  <botname>, leave #someotherchannel

The perldoc pages for the various modules will list other commands.

=head1 DESCRIPTION

Bot::BasicBot::Pluggable started as Yet Another Infobot replacement, but now
is a generalised framework for writing infobot-type bots that lets you keep
each specific function seperate. You can have seperate modules for factoid
tracking, 'seen' status, karma, googling, etc. Included default modules are
below. Use C<perldoc Bot::BasicBot::Pluggable::Module::<module name>> for help
on their individual terminology.

  Auth    - user authentication and admin access.
  DNS     - host lookup (e.g. nslookup and dns).
  Google  - search Google for things.
  Infobot - handles infobot-style factoids.
  Join    - joins and leaves channels.
  Karma   - tracks the popularity of things.
  Loader  - loads and unloads modules as bot commands.
  Seen    - tells you when people were last seen.
  Title   - gets the title of URLs mentioned in channel.
  Vars    - changes module variables.

The way the Pluggable bot works is very simple. You create a new bot object
and tell it to load various modules (or, alternatively, load just the Loader
module and then interactively load modules via an IRC /query). The modules
receive events when the bot sees things happen and can, in turn, respond. See
C<perldoc Bot::BasicBot::Pluggable::Module> for the details of the module API.



=head1 METHODS

=over 4

=item new(key => value, ...)

Create a new Bot. Identical to the C<new> method in L<Bot::BasicBot>.

=item load($module)

Load a module for the bot by name from C<./ModuleName.pm> or
C<./modules/ModuleName.pm> in that order if one of these files
exist, and falling back to C<Bot::BasicBot::Pluggable::Module::$module>
if not.



=item reload($module)

Reload the module C<$module> - equivalent to unloading it (if it's already
loaded) and reloading it. Will stomp the old module's namespace - warnings
are expected here. Not toally clean - if you're experiencing odd bugs, restart
the bot if possible. Works for minor bug fixes, etc.



=item unload($module)

Removes a module from the bot. It won't get events any more.



=item module($module)

Returns the handler object for the loaded module C<$module>. Used, e.g.,
to get the 'Auth' hander to check if a given user is authenticated.



=item modules

Returns a list of the names of all loaded modules as an array.



=item available_modules

Returns a list of all available modules whether loaded or not



=item add_handler($handler_object, $handler_name)

Adds a handler object with the given name to the queue of modules. There
is no order specified internally, so adding a module earlier does not
guarantee it'll get called first. Names must be unique.



=item remove_handler($handler_name)

Remove a handler with the given name.



=item store

Returns the bot's object store; see L<Bot::BasicBot::Pluggable::Store>.



=item dispatch($method_name, $method_params)

Call the named C<$method> on every loaded module with that method name.



=item help

Returns help for the ModuleName of message 'help ModuleName'. If no message
has been passed, return a list of all possible handlers to return help for.



=item run

Runs the bot. POE core gets control at this point; you're unlikely to get it back.

=back



=head1 BUGS

During the C<make>, C<make test>, C<make install> process, POE will moan about
its kernel not being run. This is a C<Bot::BasicBot problem>, apparently.
Reloading a module causes warnings as the old module gets its namespace stomped.
Not a lot you can do about that. All modules must be in Bot::Pluggable::Module::
namespace. Well, that's not really a bug.                                                                                       

=head1 REQUIREMENTS

Bot::BasicBot::Pluggable is based on POE, and really needs the latest version.
Because POE is like that sometimes. You also need L<POE::Component::IRC>.
Oh, and L<Bot::BasicBot>. Some of the modules will need more modules, e.g.
Google.pm needs L<Net::Google>. See the module docs for more details.

=head1 AUTHOR

Mario Domgoergen <mdom@cpan.org>

This program is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=head1 CREDITS

Bot::BasicBot was written initially by Mark Fowler, and worked on heavily by
Simon Kent, who was kind enough to apply some patches I needed for Pluggable.
Eventually. Oh, yeah, and I stole huge chunks of docs from the Bot::BasicBot
source too. I spent a lot of time in the mozbot code, and that has influenced
my ideas for Pluggable. Mostly to get round its awfulness.

Various people helped with modules. Convert was almost ported from the
infobot code by blech. But not quite. Thanks for trying... blech has also put
a lot of effort into the chump.cgi & chump.tem files in the examples/ folder,
including some /inspired/ calendar evilness.

And thanks to the rest of #2lmc who were my unwilling guinea pigs during
development. And who kept suggesting totally stupid ideas for modules that I
then felt compelled to go implement. Shout.pm owes its existence to #2lmc.

=head1 SEE ALSO

POE

L<POE::Component::IRC>

L<Bot::BasicBot>

Infobot: http://www.infobot.org/

Mozbot: http://www.mozilla.org/projects/mozbot/



