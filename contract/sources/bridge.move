module bridge::bridge {
    use std::error;
    use std::vector;
    use std::option::{Self, Option};
    use std::signer;
    use aptos_std::ed25519::{Self};
    use aptos_framework::account::{Self};
    use aptos_framework::event::{Self};
    use aptos_framework::object::{Self};
    use aptos_framework::ordered_map;
    use aptos_std::table::{Self, Table};
    use bridge::bridge_message::{Self, BridgeMessage, BridgeMessageKey};
    use bridge::mofu_nft::{Self, MofuToken};
    use bridge::bridge_config::{Self};

    // ======== Events ========

    #[event]
    struct CreateBridgeRecordEvent has drop, store {
        seq_num: u64,
        token_id: u256,
        source_addr: vector<u8>,
        target_addr: address
    }

    #[event]
    struct ClaimEvent has drop, store {
        token_id: u256,
        recipient: address
    }

    #[event]
    struct AdminWithdrawEvent has drop, store {
        token_id: u256,
        recipient: address
    }

    #[event]
    struct ValidatorAddedEvent has drop, store {
        validator_addr: vector<u8>
    }

    #[event]
    struct ValidatorRemovedEvent has drop, store {
        validator_addr: vector<u8>
    }

    #[event]
    struct TokenAlreadyClaimedEvent has drop, store {
        token_id: u256,
        recipient: address
    }

    #[event]
    struct EmergencyPauseEvent has drop, store {
        paused: bool
    }

    // ======== Error codes ========

    const ENOT_AUTHORIZED: u64 = 1;
    const EINVALID_SIGNATURE: u64 = 2;
    const EINVALID_VALIDATOR: u64 = 3;
    const EVALIDATOR_ALREADY_EXISTS: u64 = 4;
    const EINVALID_VALIDATOR_ADDR: u64 = 6;
    const EINVALID_VALIDATOR_ADDR_LENGTH: u64 = 7;
    const EALREADY_CLAIMED: u64 = 8;
    const EINVALID_RECIPIENT: u64 = 9;
    const EINVALID_VALIDATOR_PK: u64 = 10;
    const EVALIDATOR_INDEX_OUT_OF_BOUNDS: u64 = 11;
    const ERECORD_ALREADY_EXISTS: u64 = 12;
    const EPAUSED: u64 = 13;
    const ETOKEN_NOT_FOUND: u64 = 14;
    const EVALIDATOR_EXISTS: u64 = 15;
    const ERECORD_NOT_FOUND: u64 = 16;

    // ======== Struct ========

    struct BridgeRecord has store {
        message: BridgeMessage,
        verified_signature: Option<vector<u8>>,
        claimed: bool,
        recipient: address
    }

    struct BridgeRegistry has key {
        records: Table<BridgeMessageKey, BridgeRecord>,
        pending_claims: ordered_map::OrderedMap<u256, address>,
        claimed_token_ids: vector<u256>,
        validators: vector<vector<u8>>
    }

    fun init_module(owner: &signer) {
        let (resource_signer, resource_cap) =
            account::create_resource_account(owner, b"Mofu Mofu Genesis Bridge");

        mofu_nft::init(owner, &resource_signer, resource_cap);
        bridge_config::init_config(owner, signer::address_of(owner));

        move_to(
            owner,
            BridgeRegistry {
                claimed_token_ids: vector::empty<u256>(),
                validators: vector::empty<vector<u8>>(),
                records: table::new(),
                pending_claims: ordered_map::new()
            }
        );
    }

    public entry fun init(sender: &signer) acquires BridgeRegistry {
        bridge_config::assert_is_admin(sender); // Check admin authorization
        let registry = borrow_registry_mut();
        let resource_signer = mofu_nft::create_collection_signer();

        for (i in 0..500) {
            let token_id = i as u256;
            let token_address = mofu_nft::mint_token(&resource_signer, token_id);

            registry.pending_claims.add(token_id, token_address);
        }
    }

    public entry fun add_validator(
        sender: &signer, validator_addr: vector<u8>
    ) acquires BridgeRegistry {
        bridge_config::assert_is_admin(sender); // Check admin authorization
        assert!(
            vector::length<u8>(&validator_addr) == 32,
            EINVALID_VALIDATOR_ADDR_LENGTH
        ); // Invalid validator address length
        assert!(find_validator_index(validator_addr) == 0, EVALIDATOR_EXISTS);
        let registry = borrow_global_mut<BridgeRegistry>(@bridge);

        vector::push_back(&mut registry.validators, validator_addr);
    }

    public entry fun create_bridge_record(
        source_addr: vector<u8>,
        target_addr: address,
        token_id: u256,
        bridge_seq_num: u64,
        validator_index: u64,
        signature: vector<u8>
    ) acquires BridgeRegistry {
        let validator = get_validator_from_registry(validator_index);

        let message_hash =
            bridge_message::create_message_hash_internal(
                source_addr,
                target_addr,
                token_id,
                bridge_seq_num
            );

        let valid = verify_validator_signature_internal(
            validator, message_hash, signature
        );

        assert!(valid, EINVALID_SIGNATURE); // Signature verification failed

        let registry = borrow_global_mut<BridgeRegistry>(@bridge);
        let key = bridge_message::create_message_key(token_id);

        assert!(
            table::contains(&registry.records, key) == false,
            ERECORD_ALREADY_EXISTS
        );

        let record = BridgeRecord {
            message: bridge_message::create_message(
                bridge_seq_num,
                token_id,
                source_addr,
                target_addr
            ),
            verified_signature: option::some(signature),
            claimed: false,
            recipient: target_addr
        };

        table::add(&mut registry.records, key, record);
        // vector::push_back(&mut registry.verified_signatures, signature);

        event::emit(
            CreateBridgeRecordEvent {
                seq_num: bridge_seq_num,
                token_id: token_id,
                source_addr: source_addr,
                target_addr: target_addr
            }
        );
    }

    /// Batch claim tokens after they have been bridged
    public entry fun batch_claim(claimer: &signer, token_ids: vector<u256>) acquires BridgeRegistry {
        asset_not_paused();
        let registry = borrow_registry_mut();

        for (i in 0..vector::length<u256>(&token_ids)) {
            let token_id = vector::borrow(&token_ids, i);
            claim_internal(registry, claimer, *token_id);
        }
    }

    /// Claim a token after it has been bridged
    public entry fun claim(claimer: &signer, token_id: u256) acquires BridgeRegistry {
        asset_not_paused();
        let registry = borrow_registry_mut();

        claim_internal(registry, claimer, token_id);
    }

    /// Set if minting is enabled for this minting contract
    public entry fun set_enabled(caller: &signer, enabled: bool) {
        bridge_config::set_enabled(caller, enabled);
    }

    /// Remove a validator from the registry
    public entry fun remove_validator(
        sender: &signer, validator_addr: vector<u8>
    ) acquires BridgeRegistry {
        bridge_config::assert_is_admin(sender); // Check admin authorization

        let index = find_validator_index(validator_addr);
        assert!(index > 0, 3); // Validator does not exist

        let registry = borrow_global_mut<BridgeRegistry>(@bridge);
        vector::remove(&mut registry.validators, index - 1);
    }

    fun claim_internal(
        registry: &mut BridgeRegistry, claimer: &signer, token_id: u256
    ) {
        assert!(
            registry.pending_claims.contains(&token_id),
            error::not_found(ETOKEN_NOT_FOUND)
        ); // Token not found
        let key = bridge_message::create_message_key(token_id);
        assert!(
            registry.records.contains(key),
            error::not_found(ERECORD_NOT_FOUND)
        ); // Bridge record not found

        let bridge_record = table::borrow_mut(&mut registry.records, key);
        let claimer_addr = signer::address_of(claimer);

        assert!(
            bridge_record.claimed == false,
            error::already_exists(EALREADY_CLAIMED)
        ); // Already claimed
        assert!(
            bridge_record.recipient == claimer_addr,
            error::unavailable(EINVALID_RECIPIENT)
        ); // Not the recipient

        let token_address = registry.pending_claims.borrow(&token_id);
        let token_object = object::address_to_object<MofuToken>(*token_address);
        let resource_signer = mofu_nft::create_collection_signer();

        object::transfer(&resource_signer, token_object, claimer_addr);
        registry.pending_claims.remove(&token_id);
        vector::push_back(&mut registry.claimed_token_ids, token_id);

        bridge_record.claimed = true;
        event::emit(ClaimEvent { recipient: claimer_addr, token_id: token_id });
    }

    fun find_validator_index(validator_addr: vector<u8>): u64 acquires BridgeRegistry {
        let validators = get_validators_from_registry();
        let index = 0;

        for (i in 0..vector::length<vector<u8>>(&validators)) {
            let exist_validator_addr = vector::borrow(&validators, i);
            if (exist_validator_addr == &validator_addr) {
                index = i + 1;
                break;
            }
        };

        index
    }

    inline fun asset_not_paused() {
        assert!(bridge_config::is_enabled(), error::invalid_state(EPAUSED))
    }

    inline fun borrow_registry(): &BridgeRegistry acquires BridgeRegistry {
        borrow_global<BridgeRegistry>(@bridge)
    }

    inline fun borrow_registry_mut(): &mut BridgeRegistry acquires BridgeRegistry {
        borrow_global_mut<BridgeRegistry>(@bridge)
    }

    inline fun get_validator_from_registry(index: u64): vector<u8> acquires BridgeRegistry {
        let registry = borrow_global<BridgeRegistry>(@bridge);
        assert!(
            index < vector::length<vector<u8>>(&registry.validators),
            EVALIDATOR_INDEX_OUT_OF_BOUNDS
        ); // Index out of bounds

        *vector::borrow(&registry.validators, index)
    }

    // ======== View ========

    #[view]
    public fun is_token_claimed(token_id: u256): bool acquires BridgeRegistry {
        let registry = borrow_registry();
        vector::contains(&registry.claimed_token_ids, &token_id)
    }

    #[view]
    public fun is_token_bridged(token_id: u256): bool acquires BridgeRegistry {
        let registry = borrow_registry();

        registry.records.contains(bridge_message::create_message_key(token_id))
    }

    #[view]
    public fun get_validators_from_registry(): vector<vector<u8>> acquires BridgeRegistry {
        let registry = borrow_global<BridgeRegistry>(@bridge);
        registry.validators
    }

    #[view]
    public fun has_enabled(): bool {
        bridge_config::is_enabled()
    }

    #[view]
    public fun get_validator_count(): u64 acquires BridgeRegistry {
        let validators = get_validators_from_registry();
        vector::length(&validators)
    }

    #[view]
    public fun get_validator(index: u64): vector<u8> acquires BridgeRegistry {
        get_validator_from_registry(index)
    }

    fun verify_validator_signature_internal(
        validator_addr: vector<u8>, message: vector<u8>, signature_bytes: vector<u8>
    ): bool acquires BridgeRegistry {

        let index = find_validator_index(validator_addr);
        assert!(index > 0, EVALIDATOR_ALREADY_EXISTS); // Validator does not exist

        let option_pk = ed25519::new_validated_public_key_from_bytes(validator_addr);

        assert!(option::is_some(&option_pk), EINVALID_VALIDATOR_PK); // Invalid public key

        let pk = option::extract(&mut option_pk);

        bridge_message::verify_signature_internal(pk, message, signature_bytes)
    }

    // ======== Tests ========

    #[test_only]
    fun verify_validator_signature_internal_for_testing(
        validator_addr: vector<u8>, message: vector<u8>, signature_bytes: vector<u8>
    ): bool acquires BridgeRegistry {
        verify_validator_signature_internal(validator_addr, message, signature_bytes)
    }

    #[test_only]
    fun find_validator_index_for_testing(validator_addr: vector<u8>): u64 acquires BridgeRegistry {
        find_validator_index(validator_addr)
    }

    #[test_only]
    fun get_validator_from_registry_for_testing(index: u64): vector<u8> acquires BridgeRegistry {
        get_validator_from_registry(index)
    }

    // #[test_only]
    // fun get_token_bridge_record_for_testing(){

    // }

    #[test_only]
    fun get_pending_claims_for_testing(): ordered_map::OrderedMap<u256, address> acquires BridgeRegistry {
        let registry = borrow_registry();
        registry.pending_claims
    }

    #[test_only]
    use std::string;

    #[test_only]
    use aptos_token_objects::collection::{Self};

    #[test_only]
    fun init_for_testing(admin: &signer) acquires BridgeRegistry {
        init_module(admin);
        init(admin);
    }

    #[test(admin = @bridge, claimer = @0x33)]
    fun test_init_ok(admin: &signer) acquires BridgeRegistry {
        init_for_testing(admin);

        let resource_signer = mofu_nft::create_collection_signer();
        let collection_name = string::utf8(b"Mofu Mofu Music Caravan");
        let collection_address =
            collection::create_collection_address(
                &signer::address_of(&resource_signer), &collection_name
            );
        let collection =
            object::address_to_object<collection::Collection>(collection_address);

        assert!(collection::count(collection) == option::some(500), 0);

        let registry = borrow_global<BridgeRegistry>(@bridge);

        let pending_claims = registry.pending_claims;
        let pending_claims_length = pending_claims.length();
        assert!(pending_claims_length == 500, 0);
    }

    #[
        test(
            owner = @bridge,
            claimer = @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8
        )
    ]
    #[expected_failure(abort_code = 393232, location = bridge::bridge)]
    fun test_claim_errors_when_nft_collection_is_not_ready(
        owner: &signer, claimer: &signer
    ) acquires BridgeRegistry {
        init_for_testing(owner);

        let validator =
            x"5807b7714a65b825b9abef874deb7c45904b0919461e514815585cbb0d9118cd";
        add_validator(owner, validator);
        create_bridge_record(
            b"1234567890abcdef1234567890abcdef12345678",
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8,
            10,
            0,
            0,
            x"b52b37c6de6e9edbfe8af146ceb6e6077c1e391cda14bae836508c064d4905836e6bc2b6ec0ffba33c3e1d8a81982103469160f1c545576d068f1603a2ddde03"
        );

        // Try to claim without available token
        claim(claimer, 11);
    }

    #[test(admin = @bridge, sender = @0x1B)]
    #[expected_failure(abort_code = 327681, location = bridge::bridge_config)]
    fun test_init_errors_with_execute_by_user(
        admin: &signer, sender: &signer
    ) acquires BridgeRegistry {
        init_module(admin);
        init(sender);
    }

    #[test(admin = @bridge)]
    fun test_add_validator_ok(admin: &signer) acquires BridgeRegistry {
        let validator =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";

        init_module(admin);
        add_validator(admin, validator);
        let validator_exists = find_validator_index_for_testing(validator);
        assert!(validator_exists > 0, 0);
    }

    #[test(admin = @bridge)]
    fun test_remove_validator_ok(admin: &signer) acquires BridgeRegistry {
        let validator =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";

        // Initialize module with admin
        init_module(admin);

        add_validator(admin, validator);

        let validator_exists = find_validator_index_for_testing(validator);
        assert!(validator_exists > 0, 0);

        remove_validator(admin, validator);

        let validator_count = get_validator_count();
        assert!(validator_count == 0, 0);
    }

    #[test(admin = @bridge)]
    fun test_verify_bridge_signature_ok(admin: &signer) acquires BridgeRegistry {
        let validator =
            x"5807b7714a65b825b9abef874deb7c45904b0919461e514815585cbb0d9118cd";

        init_module(admin);

        add_validator(admin, validator);

        let validator = get_validator_from_registry(0);
        let signature =
            x"b52b37c6de6e9edbfe8af146ceb6e6077c1e391cda14bae836508c064d4905836e6bc2b6ec0ffba33c3e1d8a81982103469160f1c545576d068f1603a2ddde03";
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let token_id = 10;
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let nonce = 0;
        let message_hash =
            bridge_message::create_message_hash_internal(
                source_addr, target_addr, token_id, nonce
            );

        let valid =
            verify_validator_signature_internal_for_testing(
                validator, message_hash, signature
            );

        assert!(valid, 0); // Signature verification failed
    }

    #[test(admin = @bridge, user = @0x11)]
    #[expected_failure(abort_code = 327681, location = bridge::bridge_config)]
    fun test_add_validator_errors_with_execute_by_normal_user(
        admin: &signer, user: &signer
    ) acquires BridgeRegistry {
        let validator =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";

        init_module(admin);
        add_validator(user, validator);
    }

    #[test(admin = @bridge)]
    #[expected_failure(abort_code = EVALIDATOR_EXISTS)]
    fun test_add_validator_errors_with_already_exists(admin: &signer) acquires BridgeRegistry {
        let validator =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";

        init_module(admin);
        add_validator(admin, validator);
        add_validator(admin, validator);
    }

    #[test(admin = @bridge, user = @0x11)]
    #[expected_failure(abort_code = 327681, location = bridge::bridge_config)]
    fun test_remove_validator_errors_with_execute_by_normal_user(
        admin: &signer, user: &signer
    ) acquires BridgeRegistry {
        let validator =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";

        init_module(admin);
        add_validator(admin, validator);
        remove_validator(user, validator);
    }

    #[test(admin = @bridge)]
    fun test_create_bridge_record_ok(admin: &signer) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let token_id = 10 as u256;
        let validator_addr =
            x"5807b7714a65b825b9abef874deb7c45904b0919461e514815585cbb0d9118cd";
        let signature =
            x"b52b37c6de6e9edbfe8af146ceb6e6077c1e391cda14bae836508c064d4905836e6bc2b6ec0ffba33c3e1d8a81982103469160f1c545576d068f1603a2ddde03";

        let nonce = 0;
        init_module(admin);
        add_validator(admin, validator_addr);
        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            nonce,
            0,
            signature
        );
        let registry = borrow_registry();
        assert!(
            registry.records.contains(bridge_message::create_message_key(token_id)),
            0
        );

        let record =
            table::borrow(
                &registry.records,
                bridge_message::create_message_key(token_id)
            );

        assert!(record.claimed == false, 0); // Not yet claimed
        assert!(record.recipient == target_addr, 0); //
        let (seq_num, token_id, _source_addr, _target_addr) =
            bridge_message::extract_message(&record.message);
        assert!(seq_num == nonce, 0); // Sequence number equal
        assert!(token_id == token_id, 0); // Token ID equal
        assert!(record.verified_signature == option::some(signature), 0); // Signature verified
    }

    #[test(admin = @bridge)]
    #[expected_failure(abort_code = EVALIDATOR_INDEX_OUT_OF_BOUNDS)]
    fun test_create_bridge_record_errors_with_none_exist_validator(
        admin: &signer
    ) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let token_id = 10 as u256;
        let validator_addr =
            x"5807b7714a65b825b9abef874deb7c45904b0919461e514815585cbb0d9118cd";
        let signature =
            x"b52b37c6de6e9edbfe8af146ceb6e6077c1e391cda14bae836508c064d4905836e6bc2b6ec0ffba33c3e1d8a81982103469160f1c545576d068f1603a2ddde03";
        let nonce = 0;
        init_module(admin);

        add_validator(admin, validator_addr);

        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            nonce,
            1,
            signature
        );
    }

    #[test(admin = @bridge)]
    #[expected_failure(abort_code = 10, location = bridge::bridge)]
    fun test_create_bridge_record_errors_with_invalid_validator(
        admin: &signer
    ) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let token_id = 10 as u256;
        let signature =
            x"b52b37c6de6e9edbfe8af146ceb6e6077c1e391cda14bae836508c064d4905836e6bc2b6ec0ffba33c3e1d8a81982103469160f1c545576d068f1603a2ddde03";
        let nonce = 0;
        init_module(admin);

        add_validator(
            admin,
            x"5807b7714a65b825b9abef874deb7c45904b0919461e514815585cbb0d9118cd"
        );
        add_validator(
            admin,
            x"6807b7714a65b825b9abef874deb7c45904b0919461e514815585cbb0d9118cd"
        );

        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            nonce,
            1,
            signature
        );
    }

    #[test(admin = @bridge)]
    #[expected_failure(abort_code = ERECORD_ALREADY_EXISTS)]
    fun test_create_bridge_record_errors_with_already_exists(
        admin: &signer
    ) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let token_id = 10 as u256;
        let validator_addr =
            x"5807b7714a65b825b9abef874deb7c45904b0919461e514815585cbb0d9118cd";
        let signature =
            x"b52b37c6de6e9edbfe8af146ceb6e6077c1e391cda14bae836508c064d4905836e6bc2b6ec0ffba33c3e1d8a81982103469160f1c545576d068f1603a2ddde03";
        let nonce = 0;

        init_module(admin);

        add_validator(admin, validator_addr);

        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            nonce,
            0,
            signature
        );
        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            nonce,
            0,
            signature
        );
    }

    #[test(admin = @bridge)]
    #[expected_failure(abort_code = 2, location = bridge::bridge)]
    fun test_create_bridge_record_errors_with_invalid_signature(
        admin: &signer
    ) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let token_id = 10 as u256;
        let validator_addr =
            x"5807b7714a65b825b9abef874deb7c45904b0919461e514815585cbb0d9118cd";
        let signature =
            x"052b37c6de6e9edbfe8af146ceb6e6077c1e391cda14bae836508c064d4905836e6bc2b6ec0ffba33c3e1d8a81982103469160f1c545576d068f1603a2ddde03";
        let nonce = 0;
        init_module(admin);

        add_validator(admin, validator_addr);

        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            nonce,
            0,
            signature
        );
    }

    #[
        test(
            admin = @bridge,
            claimer = @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8
        )
    ]
    #[expected_failure(abort_code = 393230, location = bridge::bridge)]
    fun test_claim_errors_with_already_claimed(
        admin: &signer, claimer: &signer
    ) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let token_id = 10 as u256;
        let validator_addr =
            x"5807b7714a65b825b9abef874deb7c45904b0919461e514815585cbb0d9118cd";
        let signature =
            x"b52b37c6de6e9edbfe8af146ceb6e6077c1e391cda14bae836508c064d4905836e6bc2b6ec0ffba33c3e1d8a81982103469160f1c545576d068f1603a2ddde03";
        let nonce = 0;
        init_module(admin);

        add_validator(admin, validator_addr);

        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            nonce,
            0,
            signature
        );

        init(admin);
        claim(claimer, token_id);

        let registry = borrow_global<BridgeRegistry>(@bridge);
        let key = bridge_message::create_message_key(token_id);

        let bridge_record = table::borrow(&registry.records, key);
        assert!(bridge_record.claimed == true, 0); // Already claimed
        assert!(bridge_record.recipient == signer::address_of(claimer), 0); // Not the recipient

        claim(claimer, token_id);
    }

    #[test(admin = @bridge)]
    fun test_set_enabled_ok(admin: &signer) {
        init_module(admin);
        set_enabled(admin, true);
        set_enabled(admin, false);
    }

    #[test(admin = @bridge, user = @0x11)]
    #[expected_failure(abort_code = 327681, location = bridge::bridge_config)]
    fun test_set_enabled_errors_with_execute_by_normal_user(
        admin: &signer, user: &signer
    ) {
        init_module(admin);
        set_enabled(user, false);
    }

    #[
        test(
            admin = @bridge,
            claimer = @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8
        )
    ]
    #[expected_failure(abort_code = 196621, location = bridge::bridge)]
    fun test_claim_errors_with_paused(admin: &signer, claimer: &signer) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let token_id = 10 as u256;
        let validator_addr =
            x"5807b7714a65b825b9abef874deb7c45904b0919461e514815585cbb0d9118cd";
        let signature =
            x"b52b37c6de6e9edbfe8af146ceb6e6077c1e391cda14bae836508c064d4905836e6bc2b6ec0ffba33c3e1d8a81982103469160f1c545576d068f1603a2ddde03";
        let nonce = 0;
        init_module(admin);

        add_validator(admin, validator_addr);

        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            nonce,
            0,
            signature
        );

        set_enabled(admin, false);

        claim(claimer, token_id);
    }

    #[test(admin = @bridge, user = @0x11)]
    #[expected_failure(abort_code = 851977, location = bridge::bridge)]
    fun test_claim_errors_with_invalid_receipent(
        admin: &signer, user: &signer
    ) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let token_id = 10 as u256;
        let validator_addr =
            x"5807b7714a65b825b9abef874deb7c45904b0919461e514815585cbb0d9118cd";
        let signature =
            x"b52b37c6de6e9edbfe8af146ceb6e6077c1e391cda14bae836508c064d4905836e6bc2b6ec0ffba33c3e1d8a81982103469160f1c545576d068f1603a2ddde03";
        let nonce = 0;
        init_module(admin);

        add_validator(admin, validator_addr);

        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            nonce,
            0,
            signature
        );

        init(admin);

        claim(user, token_id);
    }

    #[
        test(
            admin = @bridge,
            claimer = @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8
        )
    ]
    #[expected_failure(abort_code = 393232, location = bridge::bridge)]
    fun test_claim_errors_with_invalid_token_id(
        admin: &signer, claimer: &signer
    ) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let token_id = 10 as u256;
        let validator_addr =
            x"5807b7714a65b825b9abef874deb7c45904b0919461e514815585cbb0d9118cd";
        let signature =
            x"b52b37c6de6e9edbfe8af146ceb6e6077c1e391cda14bae836508c064d4905836e6bc2b6ec0ffba33c3e1d8a81982103469160f1c545576d068f1603a2ddde03";
        let nonce = 0;
        init_module(admin);

        add_validator(admin, validator_addr);

        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            nonce,
            0,
            signature
        );

        init(admin);

        claim(claimer, 8);
    }

    #[
        test(
            sender = @bridge,
            user = @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8
        )
    ]
    fun test_batch_claim_ok(sender: &signer, user: &signer) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let token_ids = vector::empty<u256>();
        vector::push_back(&mut token_ids, 10);
        vector::push_back(&mut token_ids, 13);

        let signatures = vector::empty<vector<u8>>();
        vector::push_back(
            &mut signatures,
            x"b52b37c6de6e9edbfe8af146ceb6e6077c1e391cda14bae836508c064d4905836e6bc2b6ec0ffba33c3e1d8a81982103469160f1c545576d068f1603a2ddde03"
        );
        vector::push_back(
            &mut signatures,
            x"f8d856dd36c1b60c6ffd8ab7677948f3d67eae516bd9be111ca5463874c1b46fd89c3bdee19943beddf23332e7327434a975662f4dc73400fdcd88e0093c100e"
        );
        let validator_addr =
            x"5807b7714a65b825b9abef874deb7c45904b0919461e514815585cbb0d9118cd";
        let nonces = vector::empty<u64>();
        vector::push_back(&mut nonces, 0);
        vector::push_back(&mut nonces, 10);

        init_module(sender);

        add_validator(sender, validator_addr);

        for (i in 0..vector::length<u256>(&token_ids)) {
            let token_id = vector::borrow(&token_ids, i);
            let nonce = vector::borrow(&nonces, i);
            let signature = vector::borrow(&signatures, i);

            create_bridge_record(
                source_addr,
                target_addr,
                *token_id,
                *nonce,
                0,
                *signature
            );

            assert!(is_token_bridged(*token_id) == true, 0); // Token is claimable
        };
        init(sender);

        batch_claim(user, token_ids);
        assert!(is_token_claimed(10) == true, 0); // Token is claimed
        assert!(is_token_claimed(13) == true, 0); // Token is claimed
    }

    #[
        test(
            admin = @bridge,
            claimer = @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8
        )
    ]
    #[expected_failure(abort_code = 196621, location = bridge::bridge)]
    fun test_batch_claim_errors_with_paused(
        admin: &signer, claimer: &signer
    ) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let token_ids = vector::empty<u256>();
        vector::push_back(&mut token_ids, 10);
        vector::push_back(&mut token_ids, 13);

        let signatures = vector::empty<vector<u8>>();
        vector::push_back(
            &mut signatures,
            x"b52b37c6de6e9edbfe8af146ceb6e6077c1e391cda14bae836508c064d4905836e6bc2b6ec0ffba33c3e1d8a81982103469160f1c545576d068f1603a2ddde03"
        );
        vector::push_back(
            &mut signatures,
            x"f8d856dd36c1b60c6ffd8ab7677948f3d67eae516bd9be111ca5463874c1b46fd89c3bdee19943beddf23332e7327434a975662f4dc73400fdcd88e0093c100e"
        );
        let validator_addr =
            x"5807b7714a65b825b9abef874deb7c45904b0919461e514815585cbb0d9118cd";
        let nonces = vector::empty<u64>();
        vector::push_back(&mut nonces, 0);
        vector::push_back(&mut nonces, 10);

        init_module(admin);

        add_validator(admin, validator_addr);

        for (i in 0..vector::length<u256>(&token_ids)) {
            let token_id = vector::borrow(&token_ids, i);
            let nonce = vector::borrow(&nonces, i);
            let signature = vector::borrow(&signatures, i);

            create_bridge_record(
                source_addr,
                target_addr,
                *token_id,
                *nonce,
                0,
                *signature
            );

            assert!(is_token_bridged(*token_id) == true, 0); // Token is claimable
        };
        init(admin);

        set_enabled(admin, false);
        batch_claim(claimer, token_ids);
        assert!(is_token_claimed(10) == false, 0); // Token is claimed
        assert!(is_token_claimed(13) == false, 0); // Token is claimed
    }

    #[
        test(
            sender = @bridge,
            user = @0x859bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8
        )
    ]
    #[expected_failure(abort_code = 851977, location = bridge::bridge)]
    fun test_batch_claim_errors_with_invalid_receipent(
        sender: &signer, user: &signer
    ) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let token_ids = vector::empty<u256>();
        vector::push_back(&mut token_ids, 10);
        vector::push_back(&mut token_ids, 13);

        let signatures = vector::empty<vector<u8>>();
        vector::push_back(
            &mut signatures,
            x"b52b37c6de6e9edbfe8af146ceb6e6077c1e391cda14bae836508c064d4905836e6bc2b6ec0ffba33c3e1d8a81982103469160f1c545576d068f1603a2ddde03"
        );
        vector::push_back(
            &mut signatures,
            x"f8d856dd36c1b60c6ffd8ab7677948f3d67eae516bd9be111ca5463874c1b46fd89c3bdee19943beddf23332e7327434a975662f4dc73400fdcd88e0093c100e"
        );
        let validator_addr =
            x"5807b7714a65b825b9abef874deb7c45904b0919461e514815585cbb0d9118cd";
        let nonces = vector::empty<u64>();
        vector::push_back(&mut nonces, 0);
        vector::push_back(&mut nonces, 10);

        init_module(sender);

        add_validator(sender, validator_addr);

        for (i in 0..vector::length<u256>(&token_ids)) {
            let token_id = vector::borrow(&token_ids, i);
            let nonce = vector::borrow(&nonces, i);
            let signature = vector::borrow(&signatures, i);

            create_bridge_record(
                source_addr,
                target_addr,
                *token_id,
                *nonce,
                0,
                *signature
            );

            assert!(is_token_bridged(*token_id) == true, 0); // Token is claimable
        };
        init(sender);

        batch_claim(user, token_ids);
        assert!(is_token_claimed(10) == true, 0); // Token is not claimable
        assert!(is_token_claimed(13) == true, 0); // Token is not claimable
    }

    #[
        test(
            sender = @bridge,
            user = @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8
        )
    ]
    fun test_claim_ok(sender: &signer, user: &signer) acquires BridgeRegistry {
        let source_addr = b"1234567890abcdef1234567890abcdef12345678";
        let target_addr =
            @0x869bf628cd4dbcd4fac4c127677f97623b4345cd5a33e2e1b6d9e3df59dbc7f8;
        let token_id = 10 as u256;
        let validator_addr =
            x"5807b7714a65b825b9abef874deb7c45904b0919461e514815585cbb0d9118cd";
        let signature =
            x"b52b37c6de6e9edbfe8af146ceb6e6077c1e391cda14bae836508c064d4905836e6bc2b6ec0ffba33c3e1d8a81982103469160f1c545576d068f1603a2ddde03";
        let nonce = 0;

        init_module(sender);

        add_validator(sender, validator_addr);

        create_bridge_record(
            source_addr,
            target_addr,
            token_id,
            nonce,
            0,
            signature
        );

        init(sender);

        assert!(is_token_bridged(token_id) == true, 0); // Token is claimable
        claim(user, token_id);
        assert!(is_token_claimed(token_id) == true, 0); // Token is claimed
        let registry = borrow_global<BridgeRegistry>(@bridge);
        let key = bridge_message::create_message_key(token_id);
        let bridge_record = table::borrow(&registry.records, key);

        assert!(bridge_record.claimed == true, 0); // Already claimed
        assert!(bridge_record.recipient == signer::address_of(user), 0); //
        assert!(registry.pending_claims.contains(&token_id) == false, 0); //
        assert!(vector::length(&registry.claimed_token_ids) == 1, 0); //
        assert!(vector::contains(&registry.claimed_token_ids, &token_id) == true, 0); //
        assert!(registry.pending_claims.length() == 499, 0); //
    }

    #[test(sender = @bridge)]
    fun test_valid_signature_ok(sender: &signer) acquires BridgeRegistry {
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";
        let message =
            b"283132333435363738393061626364656631323334353637383930616263646566313233343536373840633639373739316631313633396236653437303330363465363035306432383637653061343662326164333364376634666237623164643539666436653833320a00000000000000000000000000000000000000000000000000000000000000";
        let signature =
            x"3896ac617999460c3e9014bf85b48b6d8db25c0817b78e4a502785a30878a19d6e444bba506e533dc96d4d44197b71e6733ad4e7b59418c936bad6b111c78303";
        init_module(sender);

        // Add validator
        add_validator(sender, validator_addr);

        let is_valid =
            verify_validator_signature_internal_for_testing(
                validator_addr,
                message,
                signature
                // signer::address_of(sender)
            );

        assert!(is_valid, 0); // Signature verification failed
    }

    #[test(sender = @bridge)]
    // #[expected_failure(abort_code=EINVALID_SIGNATURE)]
    fun test_invalid_signature_ok(sender: &signer) acquires BridgeRegistry {
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";
        let message =
            b"283132333435363738393061626364656631323334353637383930616263646566313233343536373840633639373739316631313633396236653437303330363465363035306432383637653061343662326164333364376634666237623164643539666436653833320a00000000000000000000000000000000000000000000000000000000000000";
        let signature =
            x"2096ac617999460c3e9014bf85b48b6d8db25c0817b78e4a502785a30878a19d6e444bba506e533dc96d4d44197b71e6733ad4e7b59418c936bad6b111c78303";
        init_module(sender);

        // Add validator
        add_validator(sender, validator_addr);

        let is_valid =
            verify_validator_signature_internal_for_testing(
                validator_addr,
                message,
                signature
                // signer::address_of(sender)
            );
        assert!(is_valid == false, 0);
    }

    #[test(sender = @bridge, user = @0x123)]
    #[expected_failure(abort_code = 327681, location = bridge::bridge_config)]
    fun test_add_validator_errors_with_user(
        sender: &signer, user: &signer
    ) acquires BridgeRegistry {
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";

        init_module(sender);

        // Add validator
        add_validator(user, validator_addr);
    }

    #[test(sender = @bridge, user = @0x123)]
    #[expected_failure(abort_code = 327681)]
    fun test_remove_validator_errors_with_user(
        sender: &signer, user: &signer
    ) acquires BridgeRegistry {
        let validator_addr =
            x"efa6aa3e931861b065196884569123cdec7ab69bb3d02a88e8f8900008f8bbf8";

        init_module(sender);

        // Add validator
        add_validator(sender, validator_addr);
        // Remove validator
        remove_validator(user, validator_addr);
    }
}
