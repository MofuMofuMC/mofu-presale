import {
  AccountAddress,
  Aptos,
  AptosConfig,
  type ClientConfig,
  Network,
  type InputGenerateTransactionPayloadData,
} from "@aptos-labs/ts-sdk";
import { getAccount } from "./config";

const PRESALE_CONTRACT_ADDRESS = process.env.MODULE_ADDRESS;

async function main() {
  const config = new AptosConfig({
    network: Network.TESTNET,
  });

  const aptos = new Aptos(config);
  const account = getAccount();

  // List of addresses to add to whitelist
  const addressesToWhitelist = [
    "0x30ff8dca978a711b19730eb767a79377023390899e5c3b07c7e6e245a4998874",
    "0x731e36c20fa090d98c5826cb0a99684158dd3c80b02aa8b60bd18e9cbb6e92d0",
    "0x30ff8dca978a711b19730eb767a79377023390899e5c3b07c7e6e245a4998874",
    "0x8919974883ea656fa4ba059819573b55b55b09850cb723aba96b76c468d09645",
    "0xc5a5732db6cbb0407852fe98a515b1c83922091bc6bf21803d91eeb196f08f9d",
    "0x5dad9eacb50bff5347bcb62b122eb69481cf61c59a629addeef3938672f9c0a1",
    "0xc4b198d029de04bb7d9314683debab736378103ef4bfaeb45457429ccb0cdc74",
    "0xc82692e1dd094c419409421a56bed941a4734da85916698106d10109a4b3d1cf",
    "0x1a985616e1c33f9047fb490bb77d87da03e5c3279f875c98b1351d262c5e2e84",
    "0x69a60a97439439b36d087836108429b9404a75da21b7a7eea68a2769ba352a2d",
    "0xa900df461e708ee4edc224d4bb0ec7e5a97941cd4bad67450188a7d46e434769",
    "0xf0f72d153aafb79d125e133439b3b2c3caae0925201180a5a0dc35a2aff02e41",
    "0xdeae2d54713c56673fd31fd2c64d0f6bbb4d0e25e974902c9de9ec9ca785b045",
    "0x46c3422f7174afab7f0a30fd00b5ffcf94d95b41e4c42b0dd952953cdb21edd1",
    "0xb14fc2a2dd92236d62bf6dfd9d07ca09d7825f23c68028bd6b5a547ecbdf87b2",
    // Add more addresses here
  ];

  console.log(
    `Adding ${addressesToWhitelist.length} addresses to whitelist...`
  );

  // Create transaction payloads for each address
  const transactions: InputGenerateTransactionPayloadData[] =
    addressesToWhitelist.map((address, index) => {
      console.log(
        `Preparing transaction ${index + 1}/${
          addressesToWhitelist.length
        }: adding ${address}`
      );

      return {
        function: `${PRESALE_CONTRACT_ADDRESS}::presale::add_to_whitelist`,
        typeArguments: [],
        functionArguments: [AccountAddress.from(address)],
      };
    });

  // Log transaction summary
  console.log(`\nPrepared ${transactions.length} whitelist additions`);

  try {
    // Sign and submit all transactions as a batch
    const batchResult = await aptos.transaction.batch.forSingleAccount({
      sender: account,
      data: transactions,
    });

    console.log("Batch whitelist addition successful");
    console.log(`Transaction details:`, JSON.stringify(batchResult, null, 2));
  } catch (error) {
    console.error("Error adding addresses to whitelist:", error);
  }
}

main()
  .then(() => {
    console.log("Batch whitelist addition process completed");
  })
  .catch((error) => {
    console.error("Error:", error);
  });
