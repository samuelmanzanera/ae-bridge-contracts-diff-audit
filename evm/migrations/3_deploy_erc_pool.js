const LiquidityPool = artifacts.require("ERCPool")
const DummyToken = artifacts.require("DummyToken")

const { deployProxy } = require('@openzeppelin/truffle-upgrades');

module.exports = async function (deployer, network, accounts) {
    let reserveAddress, safetyModuleAddress, archethicPoolSigner, poolCap, tokenAddress
    const safetyModuleFeeRate = 5 // 0.05%

    if (network == "development") {
        reserveAddress = accounts[4]
        safetyModuleAddress = accounts[5]
        archethicPoolSigner = '0xb2ebd20cc1b50bd1c68e84f1148a304fff15706c'
        poolCap = web3.utils.toWei('200')

        await deployer.deploy(DummyToken, web3.utils.toWei('200000'))

        const tokenInstance = await DummyToken.deployed()
        tokenAddress = tokenInstance.address

        console.log(`Deployed token: ${tokenAddress}`)
    }

    const instance = await deployProxy(LiquidityPool, [reserveAddress, safetyModuleAddress, safetyModuleFeeRate, archethicPoolSigner, poolCap, tokenAddress], { deployer });

    if (network == "development") {
        await instance.unlock()
    }
}