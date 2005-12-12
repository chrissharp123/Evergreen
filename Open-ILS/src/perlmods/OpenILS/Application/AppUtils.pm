package OpenILS::Application::AppUtils;
use strict; use warnings;
use base qw/OpenSRF::Application/;
use OpenSRF::Utils::Cache;
use OpenSRF::EX qw(:try);
use OpenILS::Perm;
use OpenSRF::Utils::Logger;
my $logger = "OpenSRF::Utils::Logger";


my $cache_client = "OpenSRF::Utils::Cache";

# ---------------------------------------------------------------------------
# Pile of utilty methods used accross applications.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# on sucess, returns the created session, on failure throws ERROR exception
# ---------------------------------------------------------------------------
sub start_db_session {

	my $self = shift;
	my $session = OpenSRF::AppSession->connect( "open-ils.storage" );
	my $trans_req = $session->request( "open-ils.storage.transaction.begin" );

	my $trans_resp = $trans_req->recv();
	if(ref($trans_resp) and UNIVERSAL::isa($trans_resp,"Error")) { throw $trans_resp; }
	if( ! $trans_resp->content() ) {
		throw OpenSRF::ERROR 
			("Unable to Begin Transaction with database" );
	}
	$trans_req->finish();
	return $session;
}


# returns undef if user has all of the perms provided
# returns the first failed perm on failure
sub check_user_perms {
	my($self, $user_id, $org_id, @perm_types ) = @_;

	$logger->debug("Checking perms with user : $user_id , org: $org_id, @perm_types");

	throw OpenSRF::EX::ERROR ("Invalid call to check_user_perms()")
		unless( defined($user_id) and defined($org_id) and @perm_types); 

	my $session = OpenSRF::AppSession->create("open-ils.storage");
	for my $type (@perm_types) {
		my $req = $session->request(
			"open-ils.storage.permission.user_has_perm", 
			$user_id, $type, $org_id );
		my $resp = $req->gather(1);
		if(!$resp) { 
			$session->disconnect();
			return $type; 
		}
	}

	$session->disconnect();
	return undef;
}

# checks the list of user perms.  The first one that fails returns a new
# OpenILS::Perm object of that type.  Returns undef if all perms are allowed
sub check_perms {
	my( $self, $user_id, $org_id, @perm_types ) = @_;
	my $t = $self->check_user_perms( $user_id, $org_id, @perm_types );
	return OpenILS::Event->new('PERM_FAILURE', ilsperm => $t, ilspermloc => $org_id ) if $t;
	return undef;
}



# ---------------------------------------------------------------------------
# commits and destroys the session
# ---------------------------------------------------------------------------
sub commit_db_session {
	my( $self, $session ) = @_;

	my $req = $session->request( "open-ils.storage.transaction.commit" );
	my $resp = $req->recv();

	if(!$resp) {
		throw OpenSRF::EX::ERROR ("Unable to commit db session");
	}

	if(UNIVERSAL::isa($resp,"Error")) { 
		throw $resp ($resp->stringify); 
	}

	if(!$resp->content) {
		throw OpenSRF::EX::ERROR ("Unable to commit db session");
	}

	$session->finish();
	$session->disconnect();
	$session->kill_me();
}

sub rollback_db_session {
	my( $self, $session ) = @_;

	my $req = $session->request("open-ils.storage.transaction.rollback");
	my $resp = $req->recv();
	if(UNIVERSAL::isa($resp,"Error")) { throw $resp;  }

	$session->finish();
	$session->disconnect();
	$session->kill_me();
}

# ---------------------------------------------------------------------------
# Checks to see if a user is logged in.  Returns the user record on success,
# throws an exception on error.
# ---------------------------------------------------------------------------


sub check_user_session {

	my( $self, $user_session ) = @_;

	my $session = OpenSRF::AppSession->create( "open-ils.auth" );
	my $request = $session->request("open-ils.auth.session.retrieve", $user_session );
	my $response = $request->recv();

	if(!$response) {
		throw OpenSRF::EX::User 
			("Error communication with storage server");
	}

	if(ref($response) and $response->isa("OpenSRF::EX")) {
		throw $response ($response->stringify);
	}


	my $content = $response->content;
	if( ref($content) eq 'HASH' ) {
		if(defined($content->{ilsevent}) and $content->{ilsevent} ne '0' ) {
			throw OpenSRF::EX::ERROR 
				("Session [$user_session] cannot be authenticated" );
		}
	}

	my $user = $content;
	if(!$user) {
		throw OpenSRF::EX::ERROR 
			("Session [$user_session] cannot be authenticated" );
	}

	$session->disconnect();
	$session->kill_me();

	return $user;
}

# generic simple request returning a scalar value
sub simplereq {
	my($self, $service, $method, @params) = @_;
	return $self->simple_scalar_request($service, $method, @params);
}


sub simple_scalar_request {
	my($self, $service, $method, @params) = @_;

	my $session = OpenSRF::AppSession->create( $service );
	my $request = $session->request( $method, @params );
	my $response = $request->recv(30);

	$request->wait_complete;

	if(!$request->complete) {
		throw OpenSRF::EX::ERROR ("Call to $service for method $method with params @params" . 
				"\n did not complete successfully");
	}

	if(!$response) {
		warn "No response from $service for method $method with params @params";
	}

	if(UNIVERSAL::isa($response,"Error")) {
		throw $response ("Call to $service for method $method with params @params" . 
				"\n failed with exception: " . $response->stringify );
	}


	$request->finish();
	$session->finish();
	$session->disconnect();

	my $value;

	if($response) { $value = $response->content; }
	else { $value = undef; }

	return $value;
}





my $tree						= undef;
my $orglist					= undef;
my $org_typelist			= undef;
my $org_typelist_hash	= {};

sub get_org_tree {

	my $self = shift;
	if($tree) { return $tree; }

	# see if it's in the cache
	$tree = $cache_client->new()->get_cache('_orgtree');
	if($tree) { return $tree; }

	if(!$orglist) {
		warn "Retrieving Org Tree\n";
		$orglist = $self->simple_scalar_request( 
			"open-ils.storage", 
			"open-ils.storage.direct.actor.org_unit.retrieve.all.atomic" );
	}

	if( ! $org_typelist ) {
		warn "Retrieving org types\n";
		$org_typelist = $self->simple_scalar_request( 
			"open-ils.storage", 
			"open-ils.storage.direct.actor.org_unit_type.retrieve.all.atomic" );
		$self->build_org_type($org_typelist);
	}

	$tree = $self->build_org_tree($orglist,1);
	$cache_client->new()->put_cache('_orgtree', $tree);
	return $tree;

}

my $slimtree = undef;
sub get_slim_org_tree {

	my $self = shift;
	if($slimtree) { return $slimtree; }

	# see if it's in the cache
	$slimtree = $cache_client->new()->get_cache('slimorgtree');
	if($slimtree) { return $slimtree; }

	if(!$orglist) {
		warn "Retrieving Org Tree\n";
		$orglist = $self->simple_scalar_request( 
			"open-ils.storage", 
			"open-ils.storage.direct.actor.org_unit.retrieve.all.atomic" );
	}

	$slimtree = $self->build_org_tree($orglist);
	$cache_client->new->put_cache('slimorgtree', $slimtree);
	return $slimtree;

}


sub build_org_type { 
	my($self, $org_typelist)  = @_;
	for my $type (@$org_typelist) {
		$org_typelist_hash->{$type->id()} = $type;
	}
}



sub build_org_tree {

	my( $self, $orglist, $add_types ) = @_;

	return $orglist unless ( 
			ref($orglist) and @$orglist > 1 );

	my @list = sort { 
		$a->ou_type <=> $b->ou_type ||
		$a->name cmp $b->name } @$orglist;

	for my $org (@list) {

		next unless ($org);

		if(!ref($org->ou_type()) and $add_types) {
			$org->ou_type( $org_typelist_hash->{$org->ou_type()});
		}

		next unless (defined($org->parent_ou));

		my ($parent) = grep { $_->id == $org->parent_ou } @list;
		next unless $parent;
		$parent->children([]) unless defined($parent->children); 
		push( @{$parent->children}, $org );
	}

	return $list[0];

}

sub fetch_user {
	my $self = shift;
	my $id = shift;
	return $self->simple_scalar_request(
		'open-ils.storage',
		'open-ils.storage.direct.actor.user.retrieve', $id );
}

sub checkses {
	my( $self, $session ) = @_;
	my $user; my $evt; my $e; 

	try {
		$user = $self->check_user_session($session);
	} catch Error with { $e = 1; };

	if( $e or !$user ) { $evt = OpenILS::Event->new('NO_SESSION'); }
	return ( $user, $evt );
}


sub checkrequestor {
	my( $self, $staffobj, $userid, @perms ) = @_;
	my $user; my $evt;

	$logger->debug("checkrequestor(): staff => " . $staffobj->id . ", user => $userid");

	if( $userid ne $staffobj->id ) {
		if( ! ($user = $self->fetch_user($userid)) ) {
			$evt = OpenILS::Event->new('USER_NOT_FOUND');
			return (undef, $evt);
		}
		$evt = $self->check_perms( $staffobj->id, $user->home_ou, @perms );
	}

	return ($user, $evt);
}

sub checkses_requestor {
	my( $self, $authtoken, $targetid, @perms ) = @_;
	my( $requestor, $target, $evt );

	($requestor, $evt) = $self->checkses($authtoken);
	return (undef, undef, $evt) if $evt;

	($target, $evt) = $self->checkrequestor( $requestor, $targetid, @perms );
	return( $requestor, $target, $evt);
}





1;
