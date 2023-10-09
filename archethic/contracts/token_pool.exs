@version 1

####################################
# EVM => Archethic : Request funds #
####################################

condition triggered_by: transaction, on: request_funds(end_time, amount, user_address, secret_hash), as: [
  type: "contract",
  code: valid_chargeable_code?(end_time, amount, user_address, secret_hash),
  timestamp: (
    # End time cannot be less than now or more than 1 day
    now = Time.now()
    end_time > now && end_time <= (now + 86400)
  ),
  address: (
    # Here ensure Ethereum contract exists and check rules
    # How to ensure Ethereum contract is a valid one ?
    # Maybe get the ABI of HTLC on github and compare it to the one on Ethereum
    # Then control rules
    true
  )
]

actions triggered_by: transaction, on: request_funds(_end_time, amount, _user_address, _secret_hash) do
  args = [
    #TOKEN_ADDRESS#,
    amount,
    transaction.address
  ]
  token_definition = Contract.call_function(#FACTORY_ADDRESS#, "get_token_resupply_definition", args)
  Contract.set_type "token"
  Contract.set_content token_definition
end

##########################################
# Archethic => EVM : Request secret hash #
##########################################

condition triggered_by: transaction, on: request_secret_hash(amount, user_address, chain_id), as: [
  type: "contract",
  code: valid_signed_code?(amount, user_address),
  previous_public_key: (
    # Ensure contract has enough fund to withdraw
    previous_address = Chain.get_previous_address()
    balance = Chain.get_token_balance(previous_address, #TOKEN_ADDRESS#)
    balance >= amount
  ),
  content: List.in?([#CHAIN_IDS#], chain_id)
]

actions triggered_by: transaction, on: request_secret_hash(_amount, _user_address, chain_id) do
  # Here delete old secret that hasn't been used before endTime
  contract_content = Contract.call_function(#STATE_ADDRESS#, "get_state", [])

  for key in Map.keys(contract_content) do
    htlc_map = Map.get(contract_content, key)
    if htlc_map.end_time > Time.now() do
      contract_content = Map.delete(contract_content, key)
    end
  end

  secret = Crypto.hmac(transaction.address)
  secret_hash = Crypto.hash(secret, "sha256")

  # Build signature for EVM decryption
  signature = sign_for_evm(secret_hash, chain_id)

  # Calculate endtime now + 2 hours
  now = Time.now()
  end_time = now - Math.rem(now, 60) + 7200

  # Add secret and signature in content
  htlc_map = [
    hmac_address: transaction.address,
    end_time: end_time,
    chain_id: chain_id
  ]

  htlc_genesis_address = Chain.get_genesis_address(transaction.address)

  contract_content = Map.set(contract_content, htlc_genesis_address, htlc_map)

  Contract.add_recipient address: #STATE_ADDRESS#, action: "update_state", args: [contract_content]
  Contract.add_recipient address: transaction.address, action: "set_secret_hash", args: [secret_hash, signature, end_time]
end

####################################
# Archethic => EVM : Reveal secret #
####################################

condition triggered_by: transaction, on: reveal_secret(htlc_genesis_address), as: [
  type: "transfer",
  content: (
    # Ensure htlc_genesis_address exists in pool state
    # and end_time has not been reached
    contract_content = Contract.call_function(#STATE_ADDRESS#, "get_state", [])

    valid? = false

    htlc_genesis_address = String.to_hex(htlc_genesis_address)
    htlc_map = Map.get(contract_content, htlc_genesis_address)

    if htlc_map != nil do
      valid? = htlc_map.end_time > Time.now()
    end

    valid?
  ),
  address: (
    # Here ensure Ethereum contract exists and check rules
    # How to ensure Ethereum contract is a valid one ?
    # Maybe get the ABI of HTLC on github and compare it to the one on Ethereum
    # Then control rules
    true
  )
]

actions triggered_by: transaction, on: reveal_secret(htlc_genesis_address) do
  contract_content = Contract.call_function(#STATE_ADDRESS#, "get_state", [])

  htlc_genesis_address = String.to_hex(htlc_genesis_address)
  htlc_map = Map.get(contract_content, htlc_genesis_address)

  contract_content = Map.delete(contract_content, htlc_genesis_address)

  secret = Crypto.hmac(htlc_map.hmac_address)
  # Do not use chain ID in signature for the secret reveal
  signature = sign_for_evm(secret, nil)

  Contract.add_recipient address: #STATE_ADDRESS#, action: "update_state", args: [contract_content]
  Contract.add_recipient address: htlc_genesis_address, action: "reveal_secret", args: [secret, signature]
end

condition triggered_by: transaction, on: update_code(new_code), as: [
  previous_public_key: (
		# Pool code can only be updated from the master chain if the bridge

		# Transaction is not yet validated so we need to use previous address
		# to get the genesis address
		previous_address = Chain.get_previous_address()
		Chain.get_genesis_address(previous_address) == #MASTER_GENESIS_ADDRESS#
	),
	code: Code.is_valid?(new_code)
]

actions triggered_by: transaction, on: update_code(new_code) do
  Contract.set_type "contract"
  # Keep contract state
  Contract.set_content contract.content
  Contract.set_code new_code
end

####################
# Public functions #
####################

export fun get_token_address() do
  #TOKEN_ADDRESS#
end

#####################
# Private functions #
#####################

fun valid_chargeable_code?(end_time, amount, user_address, secret_hash) do
  args = [
    end_time,
    user_address,
    #POOL_ADDRESS#,
    secret_hash,
    #TOKEN_ADDRESS#,
    amount
  ]

  expected_code = Contract.call_function(#FACTORY_ADDRESS#, "get_chargeable_htlc", args)

  Code.is_same?(expected_code, transaction.code)
end

fun valid_signed_code?(amount, user_address) do
  args = [
    user_address,
    #POOL_ADDRESS#,
    #TOKEN_ADDRESS#,
    amount
  ]

  expected_code = Contract.call_function(#FACTORY_ADDRESS#, "get_signed_htlc", args)

  Code.is_same?(expected_code, transaction.code)
end

fun sign_for_evm(data, chain_id) do
  hash = data

  if chain_id != nil do
    # Perform a first hash to combine data and chain_id
    abi_data = Evm.abi_encode("(bytes32,uint)", [data, chain_id])
    hash = Crypto.hash(abi_data, "keccak256")
  end

  prefix = String.to_hex("\x19Ethereum Signed Message:\n32")
  signature_payload = Crypto.hash("#{prefix}#{hash}", "keccak256")

  sig = Crypto.sign_with_recovery(signature_payload)

  if sig.v == 0 do
    sig = Map.set(sig, "v", 27)
  else
    sig = Map.set(sig, "v", 28)
  end

  sig
end
