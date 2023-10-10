const LiquidityPool = artifacts.require("ETHPool")

const { deployProxy } = require('@openzeppelin/truffle-upgrades');

module.exports = async function(deployer, network, accounts) {
    let reserveAddress, safetyModuleAddress, archethicPoolSigner, poolCap
    const safetyModuleFeeRate = 5 // 0.05%
    const lockTimePeriod = 7200; // 2H

    if (network == "development") {
        reserveAddress = accounts[4]
        safetyModuleAddress = accounts[5]
        archethicPoolSigner = '0x200066681c09a9a8c9352fac9b96a688a4ae0b39'
        poolCap = web3.utils.toWei('200')
    }

    if (network == "sepolia") {
        reserveAddress = "0x3FDf8f04cBe76c1376F593634096A5299B494678"
        safetyModuleAddress = "0x57B5Fe2F6A28E108208BA4965d9879FACF629442"
        poolCap = web3.utils.toWei('5')
        archethicPoolSigner = '0x28c9efc42e2cbdfb581c212fe1e918a480ca1421'
    }

    if (network == "mumbai") {
        reserveAddress = "0x64d75D315c592cCE1F83c53A201313C82b30FA8d"
        safetyModuleAddress = "0xc20BcA1a8155c65964e5280D93d379aeB3A4c2e7"
        poolCap = web3.utils.toWei('5')
        archethicPoolSigner = '0x4e57f0bf5813f5a516d23a59df1c767c4a3e8eef'
    }

    if (network == "bsc_testnet") {
        reserveAddress = "0x7F9E1c2Bb1Ab391bA9987070ED8e7db77A9c8818"
        safetyModuleAddress = "0x6f3dec2738b063D9aFe4436b1ec307D84f9C2EDe"
        poolCap = web3.utils.toWei('5')
        archethicPoolSigner = '0x461ac2fa849767e4059fd98903a61315434ccf64'
    }

    await deployProxy(LiquidityPool, [reserveAddress, safetyModuleAddress, safetyModuleFeeRate, archethicPoolSigner, poolCap, lockTimePeriod], { deployer });
}
