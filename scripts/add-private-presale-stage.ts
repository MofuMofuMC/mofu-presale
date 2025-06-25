import {
  AccountAddress,
  Aptos,
  AptosConfig,
  type ClientConfig,
  Hex,
  InputViewFunctionData,
  Network,
  U256,
  U64,
} from "@aptos-labs/ts-sdk";
import { getAccount } from "./config";

const PRESALE_CONTRACT_ADDRESS = process.env.MODULE_ADDRESS

async function main() {
  const config = new AptosConfig({
    network: Network.TESTNET,
    // clientConfig,
  });

  const aptos = new Aptos(config);

  const account = getAccount();

  const payload: InputViewFunctionData = {
    function: "0x1::timestamp::now_seconds",
  };

  const nowSeconds = (await aptos.view({ payload }))[0];

  console.log(`Now Seconds: ${nowSeconds}`);

  const txn = await aptos.transaction.build.simple({
    sender: account.accountAddress,
    data: {
      function: `${PRESALE_CONTRACT_ADDRESS}::presale::update_private_presale_stage`,
      typeArguments: [],
      functionArguments: [
        new U64(500),
        new U64(1000000),
        new U64(Number(nowSeconds)),
        new U64(Number(nowSeconds) + 3600 * 24 * 2),
      ],
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
