@version 1

####################################
# EVM => Archethic : Request funds #
####################################

condition triggered_by: transaction, on: request_funds(end_time, amount, user_address, secret_hash, evm_tx_address, evm_contract, chain_id), as: [
  type: "contract",
  code: valid_chargeable_code?(end_time, amount, user_address, secret_hash),
  timestamp: (
    # End time cannot be less than now or more than 1 day
    now = Time.now()
    end_time > now && end_time <= now + 86400
  ),
  uco_transfers: (
    # Ensure the pool has enough UCO to send the requested fund
    balance = Chain.get_uco_balance(contract.address)
    balance >= amount
  ),
  content: List.in?([@CHAIN_IDS], chain_id),
  address: (
    valid? = false

    tx_receipt_request = get_tx_receipt_request(evm_tx_address)
    body = Json.to_string([tx_receipt_request])

    chain_data = get_chain_data(chain_id)
    headers = ["Content-Type": "application/json"]

    res = Http.request(chain_data.endpoint, "POST", headers, body)
    if res.status == 200 && res.body != nil do
      responses = Json.parse(res.body)

      tx_receipt = get_tx_receipt_response(responses)
      
      valid? = valid_tx_receipt?(tx_receipt, chain_data.proxy_address, evm_contract)
    end

    valid?
  )
]

actions triggered_by: transaction, on: request_funds(_, amount, _, _, _, _, _) do
  Contract.set_type("transfer")
  Contract.add_uco_transfer(to: transaction.address, amount: amount)
end

##########################################
# Archethic => EVM : Request secret hash #
##########################################

condition triggered_by: transaction, on: request_secret_hash(htlc_genesis_address, amount, user_address, chain_id), as: [
  type: "transfer",
  code: valid_signed_code?(htlc_genesis_address, amount, user_address),
  previous_public_key:
    (
      # Ensure contract has enough fund to withdraw
      previous_address = Chain.get_previous_address()
      balance = Chain.get_uco_balance(previous_address)
      balance >= amount
    ),
  content: List.in?([@CHAIN_IDS], chain_id),
  uco_transfers:
    (
      htlc_genesis_address = String.to_hex(htlc_genesis_address)
      Map.get(htlc_genesis_address) == amount
    )
]

actions triggered_by: transaction, on: request_secret_hash(htlc_genesis_address, _amount, _user_address, chain_id) do
  # Here delete old secret that hasn't been used before endTime
  contract_content = Map.new()

  if Json.is_valid?(contract.content) do
    contract_content = Json.parse(contract.content)
  end

  for key in Map.keys(contract_content) do
    htlc_map = Map.get(contract_content, key)

    if htlc_map.end_time <= Time.now() do
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

  htlc_genesis_address = String.to_hex(htlc_genesis_address)
  contract_content = Map.set(contract_content, htlc_genesis_address, htlc_map)

  Contract.set_content(Json.to_string(contract_content))

  Contract.add_recipient(
    address: htlc_genesis_address,
    action: "set_secret_hash",
    args: [secret_hash, signature, end_time]
  )
end

####################################
# Archethic => EVM : Reveal secret #
####################################

condition triggered_by: transaction, on: reveal_secret(htlc_genesis_address), as: [
  type: "transfer",
  content:
    (
      # Ensure htlc_genesis_address exists in pool state
      # and end_time has not been reached
      valid? = false

      if Json.is_valid?(contract.content) do
        htlc_genesis_address = String.to_hex(htlc_genesis_address)
        htlc_map = Map.get(Json.parse(contract.content), htlc_genesis_address)

        if htlc_map != nil do
          valid? = htlc_map.end_time > Time.now()
        end
      end

      valid?
    ),
  # Here ensure Ethereum contract exists and check rules
  # How to ensure Ethereum contract is a valid one ?
  # Maybe get the ABI of HTLC on github and compare it to the one on Ethereum
  # Then control rules
  address: true
]

actions triggered_by: transaction, on: reveal_secret(htlc_genesis_address) do
  contract_content = Json.parse(contract.content)

  htlc_genesis_address = String.to_hex(htlc_genesis_address)
  htlc_map = Map.get(contract_content, htlc_genesis_address)

  contract_content = Map.delete(contract_content, htlc_genesis_address)

  secret = Crypto.hmac(htlc_map.hmac_address)
  # Do not use chain ID in signature for the secret reveal
  signature = sign_for_evm(secret, nil)

  Contract.set_content(Json.to_string(contract_content))

  Contract.add_recipient(
    address: htlc_genesis_address,
    action: "reveal_secret",
    args: [secret, signature]
  )
end

condition triggered_by: transaction, on: update_code(new_code), as: [
  previous_public_key:
    (
      # Pool code can only be updated from the master chain if the bridge

      # Transaction is not yet validated so we need to use previous address
      # to get the genesis address
      previous_address = Chain.get_previous_address()
      Chain.get_genesis_address(previous_address) == @MASTER_GENESIS_ADDRESS
    ),
  code: Code.is_valid?(new_code)
]

actions triggered_by: transaction, on: update_code(new_code) do
  Contract.set_type("contract")
  # Keep contract state
  Contract.set_content(contract.content)
  Contract.set_code(new_code)
end

####################
# Public functions #
####################

export fun(get_token_address()) do
  "UCO"
end

#####################
# Private functions #
#####################

fun valid_chargeable_code?(end_time, amount, user_address, secret_hash) do
  args = [
    end_time,
    user_address,
    @POOL_ADDRESS,
    secret_hash,
    "UCO",
    amount
  ]

  expected_code = Contract.call_function(@FACTORY_ADDRESS, "get_chargeable_htlc", args)

  Code.is_same?(expected_code, transaction.code)
end

fun valid_signed_code?(htlc_address, amount, user_address) do
  valid? = false

  htlc_address = String.to_hex(htlc_address)
  last_htlc_transaction = Chain.get_last_transaction(htlc_address)

  if last_htlc_transaction != nil do
    args = [
      user_address,
      @POOL_ADDRESS,
      "UCO",
      amount
    ]

    expected_code = Contract.call_function(@FACTORY_ADDRESS, "get_signed_htlc", args)

    valid? = Code.is_same?(expected_code, last_htlc_transaction.code)
  end

  valid?
end

fun get_chain_data(chain_id) do
  data = Map.new()
  @EVM_DATA_CONDITIONS
  data
end

fun get_tx_receipt_request(evm_tx_address) do
  [
    jsonrpc: "2.0",
    id: 1,
    method: "eth_getTransactionReceipt",
    params: [evm_tx_address]
  ]
end

fun get_tx_receipt_response(responses) do
  response = nil

  for res in responses do
    if res.id == 1 do
      response = Map.get(res, "result")
    end
  end

  response
end

fun valid_tx_receipt?(tx_receipt, proxy_address, evm_contract) do
  if tx_receipt != nil do
    logs = List.at(tx_receipt.logs, 0)

    # Transaction is valid
    valid_status? = tx_receipt.status == "0x1"
    # Transaction interacted with proxy address
    valid_proxy_address? = String.to_lowercase(tx_receipt.to) == proxy_address
    # Logs are comming from proxy address
    valid_logs_address? = String.to_lowercase(logs.address) == proxy_address
    # Pool contract emmited ContractMinted event
    event = List.at(logs.topics, 0)
    valid_event? = String.to_lowercase(event) == "0x8640c3cb3cba5653efe5a3766dc7a9fb9b02102a9f97fbe9ea39f0082c3bf497"
    # Contract minted match evm_contract in parameters
    decoded_data = Evm.abi_decode("(address)", List.at(logs.topics, 1))
    topic_address = List.at(decoded_data, 0)
    valid_contract_address? = topic_address == String.to_lowercase(evm_contract)
    
    valid_status? && valid_proxy_address? && valid_logs_address? && valid_event? && valid_contract_address?
  else
    false
  end
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
