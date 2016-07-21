#!/usr/bin/perl


$SIG{'INT'} = sub { die; };

package SessionWrapper {

	sub new {
		my ($class, $self, %args, $host, $user, $pass);

		($class, %args) = @_;

		$host = delete $args{'host'};
		$user = delete $args{'user'};
		$pass = delete $args{'pass'};

		# SoapStub
		$stub = new VMOMI::SoapStub(host => $host) || die "Failed to initialize SoapStub";

		# ServiceInstance
		$si = new VMOMI::ServiceInstance(
			$stub, 
    		new VMOMI::ManagedObjectReference(
    			type => 'ServiceInstance', 
    			value => 'ServiceInstance',
    		),
    	);

		# RetrieveServiceContent
		$content = $si->RetrieveServiceContent(_this => $si);

		# Login
		$session = $content->sessionManager->Login(
			userName => $user,
			password => $pass,
		);

		$self = { };
		$self->{'content'} = $content;
		$self->{'session'} = $session;

		return bless $self, $class;
	}

	sub DESTROY {
		my $self = shift;

		if (defined $self->{'content'}) {
			$self->{'content'}->sessionManager->Logout();
		}
	}

}

1;

use strict;
use warnings;

use lib 'lib';

use URI;
use VMOMI;
use JSON::XS;
use Path::Tiny;
use Data::Dumper;
use HTTP::Cookies;
use HTTP::Request;
use LWP::ConnCache;
use LWP::UserAgent;
use Log::Log4perl qw(get_logger);

my ($log, $lines, $json, $cfg, $stub, $wrapper, $content, $definitions, $version, $ua);

$json = JSON::XS->new->convert_blessed->allow_nonref;

# Load configuration
$cfg = $json->decode(path("etc/vmwrt.json")->slurp());

# Initialize Log4perl
$lines = join("\n", @{ $cfg->{'logger'} || [ ]});
Log::Log4perl::init( \$lines );
$log = Log::Log4perl::get_logger();

$SIG{__DIE__} = sub {
	if ($^S) { return; } # ignore in eval

	# http://search.cpan.org/~mschilli/Log-Log4perl-1.47/lib/Log/Log4perl/FAQ.pm#How_can_I_make_sure_my_application_logs_a_message_when_it_dies_unexpectedly?
	local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;
	my $logger = get_logger("");
	$logger->fatal(@_);
	die @_; # Now terminate really
};



# Init LWP::UserAgent; support session cookies against ServiceNow instance
$ua = initialize_useragent($cfg->{'servicenow'});
$log->debug("ServiceNow API session connected");

$wrapper = new SessionWrapper(
	host => $cfg->{'vmware'}{'host'}, 
	user => $cfg->{'vmware'}{'user'},
	pass => $cfg->{'vmware'}{'pass'},
);
$content = $wrapper->{'content'};
$log->debug("VMware API session connected");

# Load filters from configuration file
$definitions = $cfg->{'filters'};

# PropertyFilterSpec
create_filter_spec($content, $definitions);
$log->debug("VMware API filters created");

# WaitForUpdatesEx
$log->debug("Starting WaitForUpdatesEx processing loop...");
wait_for_updates($content, $ua, $cfg->{'servicenow'}, 60);

exit; 

sub initialize_useragent {
	my ($sn_cfg) = @_;

	my ($host, $user, $pass, $path, $uri, $user_agent, $cookies, $cache, $request, $response);

	$host = $sn_cfg->{'host'};
	$user = $sn_cfg->{'user'};
	$pass = $sn_cfg->{'pass'};
	$path = $sn_cfg->{'path'};

	$uri = new URI();
	$uri->scheme('https');
	$uri->host($host);
	$uri->path($path);

	$user_agent = new LWP::UserAgent(
        agent    => 'vmwrt-cmdb/perl'
    );
    
    $cache = new LWP::ConnCache();
    $cookies = new HTTP::Cookies(ignore_discard => 1);
    
    $user_agent->cookie_jar($cookies);
    $user_agent->protocols_allowed(['https']);
    $user_agent->conn_cache($cache);

    $request = new HTTP::Request();
    $request->method('GET');
    $request->uri($uri);
    $request->content_type('text/json');
    $request->authorization_basic($user, $pass);

    $response = $user_agent->request($request);
    if ($response->is_error()) {
    	die $response->status_line;
    }

    return $user_agent;
}

sub update_sn_rest {
	my ($ua, $host, $user, $pass, $path, $data) = @_;

	my ($uri, $user_agent, $cookies, $cache, $request, $response);

	$uri = new URI();
	$uri->scheme('https');
	$uri->host($host);
	$uri->path($path);

    $request = new HTTP::Request();
    $request->method('POST');
    $request->uri($uri);
    $request->content_type('application/json');
    $request->content($data);
    $request->authorization_basic($user, $pass);

    $response = $ua->request($request);
    if ($response->is_error()) {
    	die $response->status_line;
    }

    return;
}

sub create_tree_view {
	my ($content, $types) = @_;

	my $view = $content->viewManager->CreateContainerView(
		type => $types,
		recursive => 1,
		container => $content->rootFolder->moref,
	);
	return $view;
}

sub create_list_view {
	my ($content, $objects) = @_;

	my $view = $content->viewManager->CreateListView(obj => $objects);
	return $view;
}

sub create_filter_spec {
	my ($content, $definitions) = @_;

	my ($filter_spec, $tree_view, $list_view, $types, $propSets, $objectSets);

	$types = [ ];
	$propSets = [ ];

	# PropertySpecs
	foreach (@$definitions) {
		my ($spec, $type, $properties);

		$type = $_->{'type'};
		$properties = $_->{'properties'};
		$spec = new VMOMI::PropertySpec(all => 0, type => $type, pathSet => $properties);
		
		push @$types, $type;
		push @$propSets, $spec;
	}

	# CreateContainerView
	$tree_view = create_tree_view($content, $types);

	# Patch in OptionManager (VpxSettings)
	push @$types, "OptionManager";
	push @$propSets, new VMOMI::PropertySpec(
		all => 0, 
		type => "OptionManager", 
		pathSet => [ 
			'setting["VirtualCenter.InstanceName"]',
			'setting["VirtualCenter.AutoManagedIPV4"]',
			'setting["VirtualCenter.FQDN"]',
		]
	);

	# CreateListView; adds rootFolder. TODO: Add custom values and non-inventory objects
	$list_view = create_list_view($content, [
		$content->rootFolder->{'moref'},
		$content->setting->{'moref'},
	]);

	# ObjectSpecs; TraversalSpec simplified through ContainerView & ListView
	$objectSets = [
		new VMOMI::ObjectSpec(
			obj => $tree_view,
			skip => 0,
			selectSet => [ 
				new VMOMI::TraversalSpec(
					path => "view", 
					type => $tree_view->{type} ), 
			],
		),
		new VMOMI::ObjectSpec(
			obj => $list_view,
			skip => 0,
			selectSet => [
				new VMOMI::TraversalSpec(
					path => "view",
					type => $list_view->{type} ),
			]
		),
	];

	$filter_spec = new VMOMI::PropertyFilterSpec(
		reportMissingObjectsInResults => 0,
		propSet => $propSets,
		objectSet => $objectSets,
	);

	# CreateFilter(); currently not using partialUpdates
	$content->propertyCollector->CreateFilter(spec => $filter_spec, partialUpdates => 0);

	return;
}

sub wait_for_updates {
	my ($content, $ua, $sn_cfg, $wait) = @_;
	my ($version, $truncated, $initial, $about);

	$about = $content->about;
	$initial = 1;
	$version = '';
	$truncated = 0;

	while (1) {
		do {
			my ($update_set, $updates, $processed_updates, $data, $counters);

			$update_set = $content->propertyCollector->WaitForUpdatesEx(
				version => $version, 
				options => new VMOMI::WaitOptions(maxWaitSeconds => $wait),
			);
			next if not defined $update_set;

			$version   = $update_set->version;
			$truncated = defined($update_set->truncated) ? $update_set->truncated : "0";

			# Combine updates from filterSet; currently ignoring missingSet which should
			# not be present as we are not using ListView(s) and relying upon updates to 
			# the current inventory tree through ContainerView(s)
			$updates = [ ];
			foreach my $filter_set (@{$update_set->filterSet}) {
				foreach my $update (@{$filter_set->objectSet}) {
					push @$updates, $update;
				}
			}

			# TODO: Get vCenter information (aboutInfo, VPX Settings: IPAddress, Name, etc) to
			# populate cmdb_ci_vcenter table when vCenter instanceUuid is not found

			# Simplify updateSet for transport to ServiceNow REST endpoint
			$processed_updates = [ ];
			foreach my $update (@$updates) {
				my ($obj, $moid, $type, $kind, $processed_update);

				if ($update->obj->isa("VMOMI::ManagedObjectReference")) {
					$moid = $update->obj->value;
					$type = $update->obj->type;
				} else {
					$moid = $update->obj->{moref}->value;
					$type = $update->obj->{moref}->type;					
				}
				$kind = $update->kind->val;

				$processed_update = {
					moid => $moid,
					type => $type,
					kind => $kind,
					changes => [ ],
				};

				foreach my $change ( @{$update->changeSet || [ ]} ) {
					my ($name, $op, $val);

					$name = $change->name;
					$op   = $change->op->val;
					$val  = $change->val;

					$counters->{$type} = 0 if not exists $counters->{$type};
					$counters->{$type}++;

					# TODO: Patch in full_path for Folders, which will require all updates in a
					# set with tree view cached to parse out inventory path

					# TODO: Parsers to simplify arrays, simple types, and complex types for $val

					push @{$processed_update->{changes}}, {name => $name, value => $val, op => $op};
				}

				push @$processed_updates, $processed_update;
			}

			# Relationships will be the PITA here - need to map these out across update
			# sets, then send those into the CMDB for relationship mapping.  Should be 
			# an improvement vs the constant XML recursive lookups in today's model, but
			# will require getting CIs through GlideRecord queries.

			$data = $json->encode({
				initial => $initial,
				about => $about, 
				updates => $processed_updates, 
				version => $version,
			});

			# print $json->encode({items => $items, relations => undef});
			update_sn_rest(
				$ua,
				$sn_cfg->{'host'},
				$sn_cfg->{'user'},
				$sn_cfg->{'pass'},
				$sn_cfg->{'path'},
				$data,
			);

			$log->info("Processed update version ($version) " . join(", ", map{$_ => $counters->{$_}} keys %$counters));
		} until ( $truncated eq "0" );

		$initial = 0;
	}
}

