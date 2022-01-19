const { ethers } = require('hardhat');
const { Scalar } = require('ffjavascript');
const Constants = require('../constants');

function toHexStringRlp(num) {
    let numHex;
    if (typeof num === 'number' || typeof num === 'bigint' || typeof num === 'object') {
        numHex = Scalar.toString(Scalar.e(num), 16);
        // if it's an integer and it's value is 0, the standar is set to 0x, instead of 0x00 ( because says that always is codified in the shortest way)
        if (Scalar.e(num) === Scalar.e(0)) return '0x';
    } else if (typeof num === 'string') {
        numHex = num.startsWith('0x') ? num.slice(2) : num;
    }
    numHex = (numHex.length % 2 === 1) ? (`0x0${numHex}`) : (`0x${numHex}`);
    return numHex;
}

function rawTxToCustomRawTx(rawTx) {
    const tx = ethers.utils.parseTransaction(rawTx);
    const signData = ethers.utils.RLP.encode([
        toHexStringRlp(tx.nonce),
        toHexStringRlp(tx.gasPrice),
        toHexStringRlp(tx.gasLimit),
        toHexStringRlp(tx.to),
        toHexStringRlp(tx.value),
        toHexStringRlp(tx.data),
        toHexStringRlp(tx.chainId),
        '0x',
        '0x',
    ]);
    const r = tx.r.slice(2);
    const s = tx.s.slice(2);
    const v = (tx.v - tx.chainId * 2 - 35 + 27).toString(16).padStart(2, '0'); // 1 byte

    return signData.concat(r).concat(s).concat(v);
}

function customRawTxToRawTx(customRawTx) {
    const signatureCharacters = Constants.signatureBytes * 2;
    const rlpSignData = customRawTx.slice(0, -signatureCharacters);
    const signature = `0x${customRawTx.slice(-signatureCharacters)}`;

    const txFields = ethers.utils.RLP.decode(rlpSignData);

    const signatureParams = ethers.utils.splitSignature(signature);

    const v = ethers.utils.hexlify(signatureParams.v - 27 + txFields[6] * 2 + 35);
    const r = ethers.BigNumber.from(signatureParams.r).toHexString(); // does not have necessary 32 bytes
    const s = ethers.BigNumber.from(signatureParams.s).toHexString(); // does not have necessary 32 bytes
    const rlpFields = [...txFields.slice(0, -3), v, r, s];

    return ethers.utils.RLP.encode(rlpFields);
}

module.exports = {
    toHexStringRlp,
    customRawTxToRawTx,
    rawTxToCustomRawTx,
};
