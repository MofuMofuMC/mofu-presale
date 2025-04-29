module bridge::bridge_message {
    use std::vector;
    use std::option;
    use std::bcs;
    use aptos_std::ed25519::{Self};

    friend bridge::bridge;

    // ======== Constants ========

    const EINVALID_SIGNATURE: u64 = 2;
    const EINVALID_VALIDATOR: u64 = 3;
    const EINVALID_VALIDATOR_ADDR: u64 = 6;
    const EINVALID_VALIDATOR_ADDR_LENGTH: u64 = 7;
    const EINVALID_VALIDATOR_PK: u64 = 10;

    // ======== Events ========

    #[event]

    // Message structures
    struct BridgeMessage has copy, drop, store {
        seq_num: u64,
        token_id: u256,
        source_addr: vector<u8>,
        target_addr: address
    }

    struct BridgeMessageKey has copy, drop, store {
        token_id: u256
    }

    // ======== Public Package Functions ========

    public(friend) fun create_message_key(token_id: u256): BridgeMessageKey {
        BridgeMessageKey { token_id }
    }

    public(friend) fun create_message_hash_internal(
        source_addr: vector<u8>,
        target_addr: address,
        token_id: u256,
        seq_num: u64
    ): vector<u8> {
        let message = vector::empty<u8>();

        vector::append(&mut message, bcs::to_bytes(&source_addr));
        vector::append(&mut message, bcs::to_bytes(&target_addr));
        vector::append(&mut message, bcs::to_bytes(&token_id));
        vector::append(&mut message, bcs::to_bytes(&seq_num));
        message
    }

    public(friend) fun create_message(
        seq_num: u64,
        token_id: u256,
        source_addr: vector<u8>,
        target_addr: address
    ): BridgeMessage {
        let message = BridgeMessage { seq_num, token_id, source_addr, target_addr };
        message
    }

    public(friend) fun verify_signature_internal(
        public_key: ed25519::ValidatedPublicKey,
        message: vector<u8>,
        signature_bytes: vector<u8>
    ): bool {
        let sig = ed25519::new_signature_from_bytes(signature_bytes);
        let unvalidated_public_key = ed25519::public_key_to_unvalidated(&public_key);

        ed25519::signature_verify_strict(&sig, &unvalidated_public_key, message)
    }

    // ======== Private Functions ========
    // ======== Tests ========

    #[test]
    fun test_valid_signature_success() {
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";
        let message =
            b"283132333435363738393061626364656631323334353637383930616263646566313233343536373840633639373739316631313633396236653437303330363465363035306432383637653061343662326164333364376634666237623164643539666436653833320a00000000000000000000000000000000000000000000000000000000000000";
        let signature =
            x"3896ac617999460c3e9014bf85b48b6d8db25c0817b78e4a502785a30878a19d6e444bba506e533dc96d4d44197b71e6733ad4e7b59418c936bad6b111c78303";

        let option_pk = ed25519::new_validated_public_key_from_bytes(validator_addr);
        assert!(option::is_some(&option_pk), EINVALID_VALIDATOR_PK); // Invalid public key
        let pk = option::extract(&mut option_pk);

        let is_valid =
            verify_signature_internal(
                pk,
                message,
                signature
                // signer::address_of(sender)
            );

        assert!(is_valid, 0);
    }

    #[test]
    fun test_invalid_signature_fails() {
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";
        let message =
            b"283132333435363738393061626364656631323334353637383930616263646566313233343536373840633639373739316631313633396236653437303330363465363035306432383637653061343662326164333364376634666237623164643539666436653833320a00000000000000000000000000000000000000000000000000000000000000";
        let signature =
            x"3096ac617999460c3e9014bf85b48b6d8db25c0817b78e4a502785a30878a19d6e444bba506e533dc96d4d44197b71e6733ad4e7b59418c936bad6b111c78303";

        let option_pk = ed25519::new_validated_public_key_from_bytes(validator_addr);
        assert!(option::is_some(&option_pk), EINVALID_VALIDATOR_PK); // Invalid public key
        let pk = option::extract(&mut option_pk);

        let is_valid =
            verify_signature_internal(
                pk,
                message,
                signature
                // signer::address_of(sender)
            );

        assert!(is_valid == false, 0);
    }
}
