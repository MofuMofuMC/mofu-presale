import {
  AccountAddress,
  Aptos,
  AptosConfig,
  type ClientConfig,
  Deserializer,
  Hex,
  InputViewFunctionData,
  MoveVector,
  Network,
  Serializer,
  U256,
  U64,
  U8,
} from "@aptos-labs/ts-sdk";
import { getAccount } from "./config";

const PRESALE_CONTRACT_ADDRESS = process.env.MODULE_ADDRESS;
function byteString(str: string): Uint8Array {
  const encoder = new TextEncoder();
  return encoder.encode(str);
}

async function main() {
  const config = new AptosConfig({
    network: Network.TESTNET,
    // clientConfig,
  });

  const aptos = new Aptos(config);

  const account = getAccount();

  //   const ser = new Serializer();

  //   encoded.forEach((value) => {
  //     // console.log(`Value: ${value}`);
  //     ser.serializeU8(value);
  //   });
  //   //   console.log("encoded", encoded)

  //   console.log(ser.toUint8Array());

  console.log(byteString("apple"));
  const txn = await aptos.transaction.build.simple({
    sender: account.accountAddress,
    data: {
      function: `${PRESALE_CONTRACT_ADDRESS}::presale::create_referral_code`,
      typeArguments: [],
      functionArguments: [byteString("apple")],
    },
  });

  const committedTxn = await aptos.signAndSubmitTransaction({
    signer: account,
    transaction: txn,
  });

  await aptos.waitForTransaction({ transactionHash: committedTxn.hash });
  console.log(`Committed transaction: ${committedTxn.hash}`);
}

main()
  .then(() => {})
  .catch((error) => {
    console.error("Error:", error);
  });
