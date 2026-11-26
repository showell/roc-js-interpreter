# The bank race, x86/bank/bank_race.js, in Roc: a bank ledger makes N
# transfers. The same 500 accounts, the same Park-Miller generator, the same
# transfers and audits, and the same three lines printed, so x86/bank.shale
# holds it to verify.js's output the same way. Built with --opt=speed for
# the race.
#
# The JS's dictionary, a plain object keyed by the account's name, is a
# `Dict(Str, Account)` here, keyed by the same names: the race's lookup is
# by name, so the port's is too. An account is a record, and a transfer
# gives back the accounts it changed, each put back under its name.

account_count : U64
account_count = 500

first_seed : U64
first_seed = 20261126

multiplier : U64
multiplier = 48271

# 2^31 - 1.
modulus : U64
modulus = 2147483647

# A transfer is 1 to 50000 cents.
largest_amount : U64
largest_amount = 50000

audit_every : U64
audit_every = 10000

check_at : U64
check_at = 100000

# Computed offline: node x86/bank/verify.js 100000.
checksum_at : U64
checksum_at = 401234543

prime : U64
prime = 1000000007

## An account: its name, its balance in whole cents, and how many deposits,
## withdrawals and declines it has seen. Nominal, since every value of it is
## a valid account and the checksum reads each field.
Account := {
	name : Str,
	balance : U64,
	deposits : U64,
	withdrawals : U64,
	declined : U64,
}.{

	## The account after `amount` came in.
	deposit : Account, U64 -> Account
	deposit = |account, amount| {
		..account,
		balance: account.balance + amount,
		deposits: account.deposits + 1,
	}

	## The account after the money left, or after a decline was counted when
	## the balance is short.
	withdraw : Account, U64 -> [Withdrew(Account), Declined(Account)]
	withdraw = |account, amount|
		if amount > account.balance {
			Declined({ ..account, declined: account.declined + 1 })
		} else {
			Withdrew({
				..account,
				balance: account.balance - amount,
				withdrawals: account.withdrawals + 1,
			})
		}
}

## The Park-Miller generator: seed * 48271 mod 2^31 - 1. Its seed is the
## number it last drew.
Random := { seed : U64 }.{
	next : Random -> Random
	next = |random| { seed: (random.seed * multiplier) % modulus }
}

## The ledger's counts: the opening total every audit must find, the audits
## made, and how many found another total.
Ledger : {
	total : U64,
	audits : U64,
	unbalanced : U64,
}

Bank : {
	accounts : Dict(Str, Account),
	names : List(Str),
	ledger : Ledger,
	random : Random,
}

## An account's opening balance, in cents: 100.00 to 999.99 dollars.
opening : U64 -> U64
opening = |number| 10000 + (number * 7919) % 90000

# The account under `name`; every name the race looks up is the bank's.
account_named : Dict(Str, Account), Str -> Account
account_named = |accounts, name|
	match accounts.get(name) {
		Ok(account) => account
		Err(KeyNotFound) => crash "bank_race: no account named ${name}"
	}

# The name at `place`; the race's places are always below the count.
name_at : List(Str), U64 -> Str
name_at = |names, place|
	match names.get(place) {
		Ok(name) => name
		Err(_) => crash "bank_race: no name at ${place.to_str()}"
	}

# The sum of every balance, walking the dictionary's own keys.
audit : Dict(Str, Account) -> U64
audit = |accounts| {
	var $total = 0
	for name in accounts.keys() {
		$total = $total + account_named(accounts, name).balance
	}
	$total
}

# Every account's balance and counters, in the names' order, folded below
# the prime.
checksum : Bank -> U64
checksum = |bank| {
	var $folded = 0
	for name in bank.names {
		account = account_named(bank.accounts, name)
		$folded = ($folded * 31 + account.balance) % prime
		$folded = ($folded * 31 + account.deposits) % prime
		$folded = ($folded * 31 + account.withdrawals) % prime
		$folded = ($folded * 31 + account.declined) % prime
	}
	$folded
}

# The transfers numbered from + 1 to `to`. An audit follows every
# audit_every-th transfer.
transfers : Bank, { from : U64, to : U64 } -> Bank
transfers = |bank, { from, to }| {
	{ accounts, names, ledger, random } = bank
	var $accounts = accounts
	var $random = random
	var $audits = ledger.audits
	var $unbalanced = ledger.unbalanced
	var $step = from
	while $step < to {
		$random = $random.next()
		payer_name = name_at(names, $random.seed % account_count)
		$random = $random.next()
		payee_name = name_at(names, $random.seed % account_count)
		$random = $random.next()
		amount = $random.seed % largest_amount + 1
		payer = account_named($accounts, payer_name)
		payee = account_named($accounts, payee_name)
		$accounts = if payer_name == payee_name {
			$accounts
		} else {
			match payer.withdraw(amount) {
				Withdrew(paid) => {
					with_paid = $accounts.insert(payer_name, paid)
					with_paid.insert(payee_name, payee.deposit(amount))
				}
				Declined(short) => $accounts.insert(payer_name, short)
			}
		}
		$step = $step + 1
		if $step % audit_every == 0 {
			$audits = $audits + 1
			if audit($accounts) != ledger.total {
				$unbalanced = $unbalanced + 1
			}
		}
	}
	{
		accounts: $accounts,
		names,
		ledger: { ..ledger, audits: $audits, unbalanced: $unbalanced },
		random: $random,
	}
}

# The bank at the start: every account opened, the generator seeded.
opened_bank : Bank
opened_bank = {
	var $names = []
	var $accounts = Dict.empty()
	for number in 0..<account_count {
		name = "acct-${number.to_str()}"
		$names = $names.append(name)
		opened = {
			name,
			balance: opening(number),
			deposits: 0,
			withdrawals: 0,
			declined: 0,
		}
		$accounts = $accounts.insert(name, opened)
	}
	{
		accounts: $accounts,
		names: $names,
		ledger: {
			total: audit($accounts),
			audits: 0,
			unbalanced: 0,
		},
		random: { seed: first_seed },
	}
}

# N comes from the command line, so that nothing of the race is known when
# the program is compiled: Roc runs at compile time any call whose arguments
# are all known then.
main! = |arguments| {
	count = match arguments.get(0) {
		Ok(word) =>
			match U64.from_str(word) {
				Ok(given) if given >= check_at => given
				_ => crash "usage: bank_race N, N at least ${check_at.to_str()}"
			}
		Err(_) => crash "usage: bank_race N, N at least ${check_at.to_str()}"
	}
	# The first check_at transfers depend on nothing the run gives, so Roc
	# would make them while compiling; the count's minimum (check_at, since
	# the count is at least that) ties them to the run.
	early_bank = transfers(opened_bank, { from: 0, to: U64.min(count, check_at) })
	early = checksum(early_bank)
	bank = transfers(early_bank, { from: check_at, to: count })
	verdict = if early == checksum_at {
		"as expected"
	} else {
		"not ${checksum_at.to_str()}"
	}
	echo!("checksum after ${check_at.to_str()} transfers ${early.to_str()}, ${verdict}\n")
	echo!("audits ${bank.ledger.audits.to_str()}, unbalanced ${bank.ledger.unbalanced.to_str()}\n")
	echo!("made ${count.to_str()} transfers, final checksum ${checksum(bank).to_str()}\n")
	Ok({})
}
