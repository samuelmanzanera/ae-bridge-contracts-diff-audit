import fs from "fs"
import Archethic, { Crypto, Utils } from "archethic"
import config from "./config.js"

if (!config.endpoint || !config.factorySeed || !config.protocolFeeAddress) {
  console.log("Invalid config !")
  console.log("Config needs endpoint and factorySeed")
  process.exit(1)
}

main(config.endpoint, config.factorySeed, config.protocolFeeAddress)

async function main(endpoint, seed, protocolFeeAddress) {
  const archethic = new Archethic(endpoint)
  await archethic.connect()

  const factoryGenesisAddress = Utils.uint8ArrayToHex(Crypto.deriveAddress(seed, 0))
  console.log("Factory genesis address:", factoryGenesisAddress)

  let factoryCode = fs.readFileSync("./contracts/factory.exs", "utf8")
  // Replace protocol fee address
  factoryCode = factoryCode.replaceAll("#PROTOCOL_FEE_ADDRESS#", "0x" + protocolFeeAddress)

  const index = await archethic.transaction.getTransactionIndex(factoryGenesisAddress)

  const tx = archethic.transaction.new()
    .setType("contract")
    .setCode(factoryCode)
    .build(seed, index)
    .originSign(Utils.originPrivateKey)

  tx.on("fullConfirmation", (_confirmations) => {
    const txAddress = Utils.uint8ArrayToHex(tx.address)
    console.log("Transaction validated !")
    console.log("Address:", txAddress)
    console.log(endpoint + "/explorer/transaction/" + txAddress)
    process.exit(0)
  }).on("error", (context, reason) => {
    console.log("Error while sending transaction")
    console.log("Contest:", context)
    console.log("Reason:", reason)
    process.exit(1)
  }).send()
}
