package POE::Component::EasyDBI::SubProcess;

use strict;
use warnings FATAL => 'all';

# Initialize our version
our $VERSION = (qw($Revision: 0.06 $))[1];

# Use Error.pm's try/catch semantics
use Error qw( :try );

# We pass in data to POE::Filter::Reference
use POE::Filter::Reference;

# We run the actual DB connection here
use DBI;

# Autoflush to avoid weirdness
select((select(STDERR), $| = 1)[0]);
select((select(STDOUT), $| = 1)[0]);

sub new {
	my ($class, $opts) = @_;
	my $obj = bless($opts, $class);
	# Our Filter object
	$obj->{filter} = POE::Filter::Reference->new();
	$obj->{queue} = [];
	$obj->{ping_timeout} = $obj->{ping_timeout} || 0;
	return $obj;
}

# This is the subroutine that will get executed upon the fork() call by our parent
sub main {
	my $self = __PACKAGE__->new(shift);

	$self->{lastpingtime} = time();

	if (defined($self->{use_cancel})) {
		# Signal INT causes query cancel
		# XXX disabled for now
		#$SIG{INT} = sub { if ($sth) { $sth->cancel; } };
	}

#	print STDERR "[1] connecting\n";
	while (!$self->connect()) {	}

	return if ($self->{done});

	# check for data in queue first
	$self->process();

	# listen for commands from our parent
	READ: while ( sysread( STDIN, my $buffer = '', 1024 ) ) {
		# Feed the line into the filter
		# and put the data in the queue
		my $d = $self->{filter}->get( [ $buffer ] );
		
		# INPUT STRUCTURE IS:
		# $d->{action}			= SCALAR	->	WHAT WE SHOULD DO
		# $d->{sql}				= SCALAR	->	THE ACTUAL SQL
		# $d->{placeholders}	= ARRAY		->	PLACEHOLDERS WE WILL USE
		# $d->{id}				= SCALAR	->	THE QUERY ID ( FOR PARENT TO KEEP TRACK OF WHAT IS WHAT )
		# $d->{primary_key}		= SCALAR 	->	PRIMARY KEY FOR A HASH OF HASHES
		# $d->{last_insert_id}	= SCALAR|HASH	->	HASH REF OF TABLE AND FIELD OR SCALAR OF A QUERY TO RUN AFTER

		push(@{$self->{queue}},@$d);
		# process all in the queue until a problem occurs or done
		REDO:
		unless ($self->process()) {
			# oops problem...
			if ($self->{reconnect}) {
				# need to reconnect
				delete $self->{reconnect};
				# keep trying to connect
				while (!$self->connect()) {	}
				# and bail when we are told
				last READ if ($self->{done});
				goto REDO;
			}
		}
	}

	# Arrived here due to error in sysread/etc
	if ($self->{dbh}) {
		$self->{dbh}->disconnect();
	}
}

sub connect {
	my $self = shift;
	
	$self->{output} = undef;
	$self->{error} = undef;

	# Actually make the connection
	try {
		$self->{dbh} = DBI->connect(
			# The DSN we just set up
			map { $self->{$_} } qw( dsn username password ),

			# We set some configuration stuff here
			{
				# quiet!!
				'PrintError'	=>	0,

				'PrintWarn'		=>	0,

				# Automatically raise errors so we can catch them with try/catch
				'RaiseError'	=>	1,

				# Disable the DBI tracing
				'TraceLevel'	=>	0,
			}
		);

		# Check for undefined-ness
		if ( ! defined $self->{dbh} ) {
			die "Error Connecting to Database: $DBI::errstr";
		}
	} catch Error with {
		$self->output( $self->make_error( 'DBI', shift ) );
	};

	# Catch errors!
	if ($self->{error} && $self->{no_connect_failures}) {
		sleep($self->{reconnect_wait}) if ($self->{reconnect_wait});
		return 0;
	} elsif ($self->{error}) {
		# QUIT
		$self->{done} = 1;
		return 1;
	}
	
	# send connect notice
	$self->output({ id => 'DBI-CONNECTED' });
	
	return 1;
}

sub process {
	my $self = shift;

	return 0 unless (@{$self->{queue}});
	
	# Process each data structure
	foreach my $input (shift(@{$self->{queue}})) {
		$input->{action} = lc($input->{action});
		# Now, we do the actual work depending on what kind of query it was
		if ( $input->{action} eq 'exit' ) {
			# Disconnect!
			$self->{dbh}->disconnect();
			return 1;
		}

		my $now = time();
		my $needping = (($self->{ping_timeout} == 0 or $self->{ping_timeout} > 0)
			and (($now - $self->{lastpingtime}) >= $self->{ping_timeout})) ? 1 : 0;
			
		if ($self->{dbh}) {
# Don't work:
#			unless ($self->{dbh}->{Active}) {
#				# put the query back on the stack
#				unshift(@{$self->{queue}},$input);
#				# and reconnect
#				$self->{dbh}->disconnect();
#				$self->{reconnect} = 1;
#				return 0;
#			}
			if ($needping) {
				if (eval{ $self->{dbh}->ping(); }) {
					$self->{lastpingtime} = $now;
				} else {
					# put the query back on the stack
					unshift(@{$self->{queue}},$input);
					# and reconnect
					$self->{dbh}->disconnect();
					$self->{reconnect} = 1;
					return 0;
				}
			}
			#} elsif (!$self->{dbh}) {
		} else {
			#die "Database gone? : $DBI::errstr";
			# put the query back on the stack
			unshift(@{$self->{queue}},$input);
			# and reconnect
			$self->{dbh}->disconnect();
			$self->{reconnect} = 1;
			return 0;
		}

		if ( $input->{action} eq 'insert' ) {
			# Fire off the SQL and return success/failure + rows affected and insert id
			$self->db_insert( $input );
		} elsif ( $input->{action} eq 'do' ) {
			# Fire off the SQL and return success/failure + rows affected
			$self->db_do( $input );
		} elsif ( $input->{action} eq 'single' ) {
			# Return a single result
			$self->db_single( $input );
		} elsif ( $input->{action} eq 'quote' ) {
			$self->db_quote( $input );
		} elsif ( $input->{action} eq 'arrayhash' ) {
			# Get many results, then return them all at the same time in a array of hashes
			$self->db_arrayhash( $input );
		} elsif ( $input->{action} eq 'hashhash' ) {
			# Get many results, then return them all at the same time in a hash of hashes
			# on a primary key of course. the columns are returned in the cols key
			$self->db_hashhash( $input );
		} elsif ( $input->{action} eq 'hasharray' ) {
			# Get many results, then return them all at the same time in a hash of arrays
			# on a primary key of course. the columns are returned in the cols key
			$self->db_hasharray( $input );
		} elsif ( $input->{action} eq 'array' ) {
			# Get many results, then return them all at the same time in an array of comma seperated values
			$self->db_array( $input );
		} elsif ( $input->{action} eq 'hash' ) {
			# Get many results, then return them all at the same time in a hash keyed off the 
			# on a primary key of course
			$self->db_hash( $input );
		} elsif ( $input->{action} eq 'keyvalhash' ) {
			# Get many results, then return them all at the same time in a hash with
			# the first column being the key and the second being the value
			$self->db_keyvalhash( $input );
		} else {
			# Unrecognized action!
			$self->{output} = $self->make_error( $input->{id}, "Unknown action sent '$input->{id}'" );
		}
		if ($input->{id} eq 'DBI' || ($self->{output}->{error}
			&& ($self->{output}->{error} =~ m/no connection to the server/i
			|| $self->{output}->{error} =~ m/server has gone away/i
			|| $self->{output}->{error} =~ m/server closed the connection/i
			|| $self->{output}->{error} =~ m/connect failed/i))) {
			unshift(@{$self->{queue}},$input);
			$self->{dbh}->disconnect();
			$self->{reconnect} = 1;
			return 0;
		}
		$self->output;
	}
	return 1;
}

# This subroutine makes a generic error structure
sub make_error {
	my $self = shift;
	
	# Make the structure
	my $data = { id => shift };

	# Get the error, and stringify it in case of Error::Simple objects
	my $error = shift;

	if (ref($error) && ref($error) eq 'Error::Simple') {
		$data->{error} = $error->text;
	} else {
		$data->{error} = $error;
	}

	if ($data->{error} =~ m/has gone away/i || $data->{error} =~ m/lost connection/i) {
		$data->{id} = 'DBI';
	}

	$self->{error} = $data;

	# All done!
	return $data;
}

# This subroutine does a DB QUOTE
sub db_quote {
	my $self = shift;
	
	# Get the input structure
	my $data = shift;

	# The result
	my $quoted = undef;

	# Quote it!
	try {
		$quoted = $self->{dbh}->quote( $data->{sql} );
	} catch Error with {
		$self->{output} = $self->make_error( $data->{id}, shift );
	};

	# Check for errors
	if ( ! defined $self->{output} ) {
		# Make output include the results
		$self->{output} = { result => $quoted, id => $data->{id} };
	}
}

# This subroutine runs a 'SELECT ... LIMIT 1' style query on the db
sub db_single {
	# Get the dbi handle
	my $self = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $sth = undef;
	my $result = undef;

	# Check if this is a non-select statement
	if ( $data->{sql} !~ /^SELECT/i ) {
		$self->{output} = $self->make_error( $data->{id}, "SINGLE is for SELECT queries only! ( $data->{sql} )" );
		return;
	}

	# Catch any errors
	try {
		# Make a new statement handler and prepare the query
		if ($data->{no_cache}) {
			$sth = $self->{dbh}->prepare( $data->{sql} );
		} else {
			# We use the prepare_cached method in hopes of hitting a cached one...
			$sth = $self->{dbh}->prepare_cached( $data->{sql} );
		}

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$sth->execute( @{ $data->{placeholders} } );
			} catch Error with {
				die $sth->errstr;
			};
			if (defined($self->{dbh}->errstr)) { die $self->{dbh}->errstr; }
		}

		# Actually do the query!
		try {
			# There are warnings when joining a NULL field, which is undef
			no warnings;
			if (exists($data->{seperator})) {
				$result = join($data->{seperator},$sth->fetchrow_array());
			} else {
				$result = $sth->fetchrow_array();
			}		
			use warnings;
		} catch Error with {
			die $sth->errstr;
		};
		
		if (defined($self->{dbh}->errstr)) { die $self->{dbh}->errstr; }
	} catch Error with {
		$self->{output} = $self->make_error( $data->{id}, shift );
	};

	# Check if we got any errors
	if (!defined($self->{output})) {
		# Make output include the results
		$self->{output} = { result => $result, id => $data->{id} };
	}

	# Finally, we clean up this statement handle
	if (defined($sth)) {
		$sth->finish();
	}

}

# This subroutine does an insert into the db
sub db_insert {
	# Get the dbi handle
	my $self = shift;

	# Get the input structure
	my $data = shift;

	my $dsn = shift;

	# Variables we use
	my $sth = undef;
	my $rows_affected = undef;

	# Check if this is a non-insert statement
	if (ref($data->{hash}) eq 'HASH') {
		# sort so we always get a consistant list of fields in the errors :)
		my @fields = sort keys %{$data->{hash}};
		# adjust the placeholders, they should know that placeholders passed in are irrelevant
		# XXX maybe subtypes when a hash value is a HASH or ARRAY?
		$data->{placeholders} = [ map { $data->{hash}->{$_} } @fields ];
		my @holders = map { '?' } @fields;
		$data->{sql} = "INSERT INTO $data->{table} (".join(',',@fields).") VALUES (".join(',',@holders).")";
	} elsif ( $data->{sql} !~ /^INSERT/i ) {
		$self->{output} = $self->make_error( $data->{id}, "INSERT is for INSERTS only! ( $data->{sql} )" );
		return;
	}

	# Catch any errors
	try {
		# Make a new statement handler and prepare the query
		if ($data->{no_cache}) {
			$sth = $self->{dbh}->prepare( $data->{sql} );
		} else {
			# We use the prepare_cached method in hopes of hitting a cached one...
			$sth = $self->{dbh}->prepare_cached( $data->{sql} );
		}

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$rows_affected = $sth->execute( @{ $data->{placeholders} } );
			} catch Error with {
				die $sth->errstr;
			};
			if (defined($self->{dbh}->errstr)) { die $self->{dbh}->errstr; }
		}
	} catch Error with {
		$self->{output} = $self->make_error( $data->{id}, shift );
	};


	# If rows_affected is not undef, that means we were successful
	if ( defined $rows_affected && ! defined($self->{output})) {
		# Make the data structure
		$self->{output} = { rows => $rows_affected, result => $rows_affected, id => $data->{id} };
		
		unless ($data->{last_insert_id}) {
			return;
		}
		# get the last insert id
		try {
			my $qry = '';
			if (ref($data->{last_insert_id}) eq 'HASH') {
				my $l = $data->{last_insert_id};
				# checks for different database types
				if ($dsn =~ m/dbi:pg/i) {
					$qry = "SELECT $l->{field} FROM $l->{table} WHERE oid='".$sth->{'pg_oid_status'}."'";
				} elsif ($dsn =~ m/dbi:mysql/i) {
					if (defined($self->{dbh}->{'mysql_insertid'})) {
						$self->{output}->{insert_id} = $self->{dbh}->{'mysql_insertid'};
						return;
					} else {
						$qry = 'SELECT LAST_INSERT_ID()';
					}
				} elsif ($dsn =~ m/dbi:oracle/i) {
					$qry = "SELECT $l->{field} FROM $l->{table}";
				} else {
					die "EasyDBI doesn't know how to handle a last_insert_id with your dbi, contact the author.";
				}
			} else {
				# they are supplying thier own query
				$qry = $data->{last_insert_id};
			}
			try {
				$self->{output}->{insert_id} = $self->{dbh}->selectrow_array($qry);
			} catch Error with {
				die $sth->error;
			};
			
			if (defined($self->{dbh}->errstr)) { die $self->{dbh}->errstr; }
		} catch Error with {
			# special case, insert was ok, but last_insert_id errored
			$self->{output}->{error} = shift;
		};
	} elsif ( !defined $rows_affected && !defined($self->{output})) {
		# Internal error...
		$self->{output} = $self->make_error( $data->{id}, 'Internal Error in db_do of EasyDBI Subprocess' );
		#die 'Internal Error in db_do';
	}

	# Finally, we clean up this statement handle
	if ( defined $sth ) {
		$sth->finish();
	}
}

# This subroutine runs a 'DO' style query on the db
sub db_do {
	# Get the dbi handle
	my $self = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $sth = undef;
	my $rows_affected = undef;

	# Check if this is a non-select statement
#	if ( $data->{sql} =~ /^SELECT/i ) {
#		$self->{output} = $self->make_error( $data->{id}, "DO is for non-SELECT queries only! ( $data->{sql} )" );
#		return;
#	}

	# Catch any errors
	try {
		# Make a new statement handler and prepare the query
		if ($data->{no_cache}) {
			$sth = $self->{dbh}->prepare( $data->{sql} );
		} else {
			# We use the prepare_cached method in hopes of hitting a cached one...
			$sth = $self->{dbh}->prepare_cached( $data->{sql} );
		}

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$rows_affected = $sth->execute( @{ $data->{placeholders} } );
			} catch Error with {
				die $sth->errstr;
			};
			if (defined($self->{dbh}->errstr)) { die $self->{dbh}->errstr; }
		}
	} catch Error with {
		$self->{output} = $self->make_error( $data->{id}, shift );
	};

	# If rows_affected is not undef, that means we were successful
	if ( defined $rows_affected && !defined($self->{output})) {
		# Make the data structure
		$self->{output} = { result => $rows_affected, rows => $rows_affected, id => $data->{id} };
	} elsif ( ! defined $rows_affected && !defined $self->{output}) {
		# Internal error...
		$self->{output} = $self->make_error( $data->{id}, 'Internal Error in db_do of EasyDBI Subprocess' );
		#die 'Internal Error in db_do';
	}

	# Finally, we clean up this statement handle
	if ( defined $sth ) {
		$sth->finish();
	}
}

sub db_arrayhash {
	# Get the dbi handle
	my $self = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $sth = undef;
	my $result = [];

	# Check if this is a non-select statement
	if ( $data->{sql} !~ /^SELECT/i ) {
		$self->{output} = $self->make_error( $data->{id}, "ARRAYHASH is for SELECT queries only! ( $data->{sql} )" );
		return;
	}

	# Catch any errors
	try {
		# Make a new statement handler and prepare the query
		if ($data->{no_cache}) {
			$sth = $self->{dbh}->prepare( $data->{sql} );
		} else {
			# We use the prepare_cached method in hopes of hitting a cached one...
			$sth = $self->{dbh}->prepare_cached( $data->{sql} );
		}
		
		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$sth->execute( @{ $data->{placeholders} } );
			} catch Error with {
				die $sth->errstr;
			};
			if (defined($self->{dbh}->errstr)) { die $self->{dbh}->errstr; }
		}

#		my $newdata;
#
#		# Bind the columns
#		try {
#			$sth->bind_columns( \( @$newdata{ @{ $sth->{'NAME_lc'} } } ) );
#		} catch Error with {
#			die $sth->errstr;
#		};

		# Actually do the query!
		try {
			my $rows = 0;
			while ( my $hash = $sth->fetchrow_hashref() ) {
				if (exists($data->{chunked}) && defined($self->{output})) {
					# chunk results ready to send
					$self->output();
					$result = [];
					$rows = 0;
				}
				$rows++;
				# Copy the data, and push it into the array
				push( @{ $result }, { %{ $hash } } );
				if (exists($data->{chunked}) && $data->{chunked} == $rows) {
					# Make output include the results
					$self->{output} = { id => $data->{id}, result => $result, chunked => $data->{chunked} };
				}
			}
			# in the case that our rows == chunk
			$self->{output} = undef;

		} catch Error with {
			die $sth->errstr;
		};
		# XXX is dbh->err the same as sth->err?
		if (defined($self->{dbh}->errstr)) { die $self->{dbh}->errstr; }

		# Check for any errors that might have terminated the loop early
		if ( $sth->err() ) {
			# Premature termination!
			die $sth->errstr;
		}
	} catch Error with {
		$self->{output} = $self->make_error( $data->{id}, shift );
	};

	# Check if we got any errors
	if (!defined($self->{output})) {
		# Make output include the results
		$self->{output} = { id => $data->{id}, result => $result };
		if (exists($data->{chunked})) {
			$self->{output}->{last_chunk} = 1;
			$self->{output}->{chunked} = $data->{chunked};
		}
	}

	# Finally, we clean up this statement handle
	if ( defined $sth ) {
		$sth->finish();
	}
}

sub db_hashhash {
	# Get the dbi handle
	my $self = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $sth = undef;
	my $result = {};

	# Check if this is a non-select statement
	if ( $data->{sql} !~ /^SELECT/i ) {
		$self->{output} = $self->make_error( $data->{id}, "HASHHASH is for SELECT queries only! ( $data->{sql} )" );
		return;
	}

	my (@cols, %col);
	
	# Catch any errors
	try {
		# Make a new statement handler and prepare the query
		if ($data->{no_cache}) {
			$sth = $self->{dbh}->prepare( $data->{sql} );
		} else {
			# We use the prepare_cached method in hopes of hitting a cached one...
			$sth = $self->{dbh}->prepare_cached( $data->{sql} );
		}

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$sth->execute( @{ $data->{placeholders} } );
			} catch Error with {
				die $sth->errstr;
			};
			if (defined($self->{dbh}->errstr)) { die $self->{dbh}->errstr; }
		}

		# The result hash
		my $newdata = {};

		# Check the primary key
		my $foundprimary = 0;

		if ($data->{primary_key} =~ m/^\d+$/) {
			# primary_key can be a 1 based index
			if ($data->{primary_key} > $sth->{NUM_OF_FIELDS}) {
#				die "primary_key ($data->{primary_key}) is out of bounds (".$sth->{NUM_OF_FIELDS}.")";
				die "primary_key ($data->{primary_key}) is out of bounds";
			}
			
			$data->{primary_key} = $sth->{NAME}->[($data->{primary_key}-1)];
		}
		
		# Find the column names
		for my $i ( 0 .. $sth->{NUM_OF_FIELDS}-1 ) {
			$col{$sth->{NAME}->[$i]} = $i;
			push(@cols, $sth->{NAME}->[$i]);
			$foundprimary = 1 if ($sth->{NAME}->[$i] eq $data->{primary_key});
		}
		
		unless ($foundprimary == 1) {
			die "primary key ($data->{primary_key}) not found";
		}
		
		# Actually do the query!
		try {
			my $rows = 0;
			while ( my @row = $sth->fetchrow_array() ) {
				if (exists($data->{chunked}) && defined($self->{output})) {
					# chunk results ready to send
					$self->output();
					$result = {};
					$rows = 0;
				}
				$rows++;
				foreach my $c (@cols) {
					$result->{$row[$col{$data->{primary_key}}]}{$c} = $row[$col{$c}];
				}
				if (exists($data->{chunked}) && $data->{chunked} == $rows) {
					# Make output include the results
					$self->{output} = { result => $result, id => $data->{id}, cols => [ @cols ], chunked => $data->{chunked}, primary_key => $data->{primary_key} };
				}
			}
			# in the case that our rows == chunk
			$self->{output} = undef;
			
		} catch Error with {
			die $sth->errstr;
		};
		
		if (defined($self->{dbh}->errstr)) { die $self->{dbh}->errstr; }

		# Check for any errors that might have terminated the loop early
		if ( $sth->err() ) {
			# Premature termination!
			die $sth->errstr;
		}
	} catch Error with {
		$self->{output} = $self->make_error( $data->{id}, shift );
	};

	# Check if we got any errors
	if (!defined($self->{output})) {
		# Make output include the results
		$self->{output} = { id => $data->{id}, result => $result, cols => [ @cols ], primary_key => $data->{primary_key} };
		if (exists($data->{chunked})) {
			$self->{output}->{last_chunk} = 1;
			$self->{output}->{chunked} = $data->{chunked};
		}
	}

	# Finally, we clean up this statement handle
	if ( defined $sth ) {
		$sth->finish();
	}
}

sub db_hasharray {
	# Get the dbi handle
	my $self = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $sth = undef;
	my $result = {};

	# Check if this is a non-select statement
	if ( $data->{sql} !~ /^SELECT/i ) {
		$self->{output} = $self->make_error( $data->{id}, "HASHARRAY is for SELECT queries only! ( $data->{sql} )" );
		return;
	}

	my (@cols, %col);
	
	# Catch any errors
	try {
		# Make a new statement handler and prepare the query
		if ($data->{no_cache}) {
			$sth = $self->{dbh}->prepare( $data->{sql} );
		} else {
			# We use the prepare_cached method in hopes of hitting a cached one...
			$sth = $self->{dbh}->prepare_cached( $data->{sql} );
		}

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$sth->execute( @{ $data->{placeholders} } );
			} catch Error with {
				die $sth->errstr;
			};
			if (defined($self->{dbh}->errstr)) { die $self->{dbh}->errstr; }
		}

		# The result hash
		my $newdata = {};

		# Check the primary key
		my $foundprimary = 0;

		if ($data->{primary_key} =~ m/^\d+$/) {
			# primary_key can be a 1 based index
			if ($data->{primary_key} > $sth->{NUM_OF_FIELDS}) {
#				die "primary_key ($data->{primary_key}) is out of bounds (".$sth->{NUM_OF_FIELDS}.")";
				die "primary_key ($data->{primary_key}) is out of bounds";
			}
			
			$data->{primary_key} = $sth->{NAME}->[($data->{primary_key}-1)];
		}
		
		# Find the column names
		for my $i ( 0 .. $sth->{NUM_OF_FIELDS}-1 ) {
			$col{$sth->{NAME}->[$i]} = $i;
			push(@cols, $sth->{NAME}->[$i]);
			$foundprimary = 1 if ($sth->{NAME}->[$i] eq $data->{primary_key});
		}
		
		unless ($foundprimary == 1) {
			die "primary key ($data->{primary_key}) not found";
		}
		
		# Actually do the query!
		try {
			my $rows = 0;
			while ( my @row = $sth->fetchrow_array() ) {
				if (exists($data->{chunked}) && defined($self->{output})) {
					# chunk results ready to send
					$self->output();
					$result = {};
					$rows = 0;
				}
				$rows++;
				push(@{ $result->{$row[$col{$data->{primary_key}}]} }, @row);
				if (exists($data->{chunked}) && $data->{chunked} == $rows) {
					# Make output include the results
					$self->{output} = { result => $result, id => $data->{id}, cols => [ @cols ], chunked => $data->{chunked}, primary_key => $data->{primary_key} };
				}
			}
			# in the case that our rows == chunk
			$self->{output} = undef;
			
		} catch Error with {
			die $sth->errstr;
		};
		
		if (defined($self->{dbh}->errstr)) { die $self->{dbh}->errstr; }

		# Check for any errors that might have terminated the loop early
		if ( $sth->err() ) {
			# Premature termination!
			die $sth->errstr;
		}
	} catch Error with {
		$self->{output} = $self->make_error( $data->{id}, shift );
	};

	# Check if we got any errors
	if ( ! defined($self->{output})) {
		# Make output include the results
		$self->{output} = { result => $result, id => $data->{id}, cols => [ @cols ], primary_key => $data->{primary_key} };
		if (exists($data->{chunked})) {
			$self->{output}->{last_chunk} = 1;
			$self->{output}->{chunked} = $data->{chunked};
		}
	}

	# Finally, we clean up this statement handle
	if ( defined $sth ) {
		$sth->finish();
	}
}

sub db_array {
	# Get the dbi handle
	my $self = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $sth = undef;
	my $result = [];

	# Check if this is a non-select statement
	if ( $data->{sql} !~ /^SELECT/i ) {
		$self->{output} = $self->make_error( $data->{id}, "ARRAY is for SELECT queries only! ( $data->{sql} )" );
		return;
	}

	# Catch any errors
	try {
		# Make a new statement handler and prepare the query
		if ($data->{no_cache}) {
			$sth = $self->{dbh}->prepare( $data->{sql} );
		} else {
			# We use the prepare_cached method in hopes of hitting a cached one...
			$sth = $self->{dbh}->prepare_cached( $data->{sql} );
		}

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$sth->execute( @{ $data->{placeholders} } );
			} catch Error with {
				die $sth->errstr;
			};
			if (defined($self->{dbh}->errstr)) { die $self->{dbh}->errstr; }
		}

		# The result hash
		my $newdata = {};
		
		# Actually do the query!
		try {
			my $rows = 0;	
			while ( my @row = $sth->fetchrow_array() ) {
				if (exists($data->{chunked}) && defined($self->{output})) {
					# chunk results ready to send
					$self->output();
					$result = [];
					$rows = 0;
				}
				$rows++;
				# There are warnings when joining a NULL field, which is undef
				no warnings;
				if (exists($data->{seperator})) {
					push(@{$result},join($data->{seperator},@row));
				} else {
					push(@{$result},join(',',@row));
				}
				use warnings;
				if (exists($data->{chunked}) && $data->{chunked} == $rows) {
					# Make output include the results
					$self->{output} = { result => $result, id => $data->{id}, chunked => $data->{chunked} };
				}
			}
			# in the case that our rows == chunk
			$self->{output} = undef;
			
		} catch Error with {
			die $!;
			#die $sth->errstr;
		};
		
		if (defined($self->{dbh}->errstr)) { die $self->{dbh}->errstr; }

		# Check for any errors that might have terminated the loop early
		if ( $sth->err() ) {
			# Premature termination!
			die $sth->errstr;
		}
	} catch Error with {
		$self->{output} = $self->make_error( $data->{id}, shift );
	};

	# Check if we got any errors
	if (!defined($self->{output})) {
		# Make output include the results
		$self->{output} = { result => $result, id => $data->{id} };
		if (exists($data->{chunked})) {
			$self->{output}->{last_chunk} = 1;
			$self->{output}->{chunked} = $data->{chunked};
		}
	}

	# Finally, we clean up this statement handle
	if ( defined $sth ) {
		$sth->finish();
	}
}

sub db_hash {
	# Get the dbi handle
	my $self = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $sth = undef;
	my $result = {};

	# Check if this is a non-select statement
	if ( $data->{sql} !~ /^SELECT/i ) {
		$self->{output} = $self->make_error( $data->{id}, "HASH is for SELECT queries only! ( $data->{sql} )" );
		return;
	}

	# Catch any errors
	try {
		# Make a new statement handler and prepare the query
		if ($data->{no_cache}) {
			$sth = $self->{dbh}->prepare( $data->{sql} );
		} else {
			# We use the prepare_cached method in hopes of hitting a cached one...
			$sth = $self->{dbh}->prepare_cached( $data->{sql} );
		}

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$sth->execute( @{ $data->{placeholders} } );
			} catch Error with {
				die $sth->errstr;
			};
			if (defined($self->{dbh}->errstr)) { die $self->{dbh}->errstr; }
		}

		# The result hash
		my $newdata = {};
		
		# Actually do the query!
		try {

			my @row = $sth->fetchrow_array();
			
			if (@row) {
				for my $i ( 0 .. $sth->{NUM_OF_FIELDS}-1 ) {
					$result->{$sth->{NAME}->[$i]} = $row[$i];
				}
			}
			
		} catch Error with {
			die $sth->errstr;
		};
		
		if (defined($self->{dbh}->errstr)) { die $self->{dbh}->errstr; }

		# Check for any errors that might have terminated the loop early
		if ( $sth->err() ) {
			# Premature termination!
			die $sth->errstr;
		}
	} catch Error with {
		$self->{output} = $self->make_error( $data->{id}, shift );
	};

	# Check if we got any errors
	if (!defined $self->{output}) {
		# Make output include the results
		$self->{output} = { result => $result, id => $data->{id} };
	}

	# Finally, we clean up this statement handle
	if ( defined $sth ) {
		$sth->finish();
	}
}

sub db_keyvalhash {
	# Get the dbi handle
	my $self = shift;

	# Get the input structure
	my $data = shift;

	# Variables we use
	my $sth = undef;
	my $result = {};

	# Check if this is a non-select statement
	if ( $data->{sql} !~ /^SELECT/i ) {
		$self->{output} = $self->make_error( $data->{id}, "KEYVALHASH is for SELECT queries only! ( $data->{sql} )" );
		return;
	}

	# Catch any errors
	try {
		# Make a new statement handler and prepare the query
		if ($data->{no_cache}) {
			$sth = $self->{dbh}->prepare( $data->{sql} );
		} else {
			# We use the prepare_cached method in hopes of hitting a cached one...
			$sth = $self->{dbh}->prepare_cached( $data->{sql} );
		}

		# Check for undef'ness
		if ( ! defined $sth ) {
			die 'Did not get a statement handler';
		} else {
			# Execute the query
			try {
				$sth->execute( @{ $data->{placeholders} } );
			} catch Error with {
				die $sth->errstr;
			};
			if (defined($self->{dbh}->errstr)) { die $self->{dbh}->errstr; }
		}

		# Actually do the query!
		try {
			my $rows = 0;
			while (my @row = $sth->fetchrow_array()) {
				if ($#row < 1) {
					die 'You need at least 2 columns selected for a keyvalhash query';
				}
				if (exists($data->{chunked}) && defined($self->{output})) {
					# chunk results ready to send
					$self->output();
					$result = {};
					$rows = 0;
				}
				$rows++;
				$result->{$row[0]} = $row[1];
				if (exists($data->{chunked}) && $data->{chunked} == $rows) {
					# Make output include the results
					$self->{output} = { result => $result, id => $data->{id}, chunked => $data->{chunked} };
				}
			}
			# in the case that our rows == chunk
			$self->{output} = undef;
			
		} catch Error with {
			die $sth->errstr;
		};
		
		if (defined($self->{dbh}->errstr)) { die $self->{dbh}->errstr; }

		# Check for any errors that might have terminated the loop early
		if ( $sth->err() ) {
			# Premature termination!
			die $sth->errstr;
		}
	} catch Error with {
		$self->{output} = $self->make_error( $data->{id}, shift);
	};

	# Check if we got any errors
	if (!defined($self->{output})) {
		# Make output include the results
		$self->{output} = { result => $result, id => $data->{id} };
		if (exists($data->{chunked})) {
			$self->{output}->{last_chunk} = 1;
			$self->{output}->{chunked} = $data->{chunked};
		}
	}

	# Finally, we clean up this statement handle
	if ( defined $sth ) {
		$sth->finish();
	}
}

# Prints any output to STDOUT
sub output {
	my $self = shift;
	
	# Get the data
	my $data = shift || undef;

	unless (defined($data)) {
		$data = $self->{output};
		$self->{output} = undef;
		# TODO use this at some point
		$self->{error} = undef;
	}
	
	# Freeze it!
	my $outdata = $self->{filter}->put( [ $data ] );

	# Print it!
	print STDOUT @$outdata;
}

1;

__END__

=head1 NAME

POE::Component::EasyDBI::SubProcess - Backend of POE::Component::EasyDBI

=head1 ABSTRACT

This module is responsible for implementing the guts of POE::Component::EasyDBI.
The fork and the connection to the DBI.

=head2 EXPORT

Nothing.

=head1 SEE ALSO

L<POE::Component::EasyDBI>

L<DBI>

L<POE>
L<POE::Wheel::Run>
L<POE::Filter::Reference>

L<POE::Component::DBIAgent>
L<POE::Component::LaDBI>
L<POE::Component::SimpleDBI>

=head1 AUTHOR

David Davis E<lt>xantus@cpan.orgE<gt>

=head1 CREDITS

Apocalypse E<lt>apocal@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2003-2004 by David Davis and Teknikill Software

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut