// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title TransientLock
 * @notice Gas-optimized transient storage reentrancy guard for Cancun EVM (EIP-1153)
 * @dev Replaces persistent SSTORE with transient TSTORE/TLOAD (100 gas vs 2100+ gas)
 */
abstract contract TransientLock {
    // keccak256("deltaforge.transient.lock.slot")
    bytes32 private constant TRANSIENT_LOCK_SLOT = 0x9a8684bbd1469e71ec7f5d9fb56fbe511df3c08fe0774a8a6190ec6118d09f7a;

    error TransientLock__ReentrantCall();

    modifier nonReentrant() {
        _enterTransient();
        _;
        _exitTransient();
    }

    function _enterTransient() internal {
        assembly {
            if tload(TRANSIENT_LOCK_SLOT) {
                // Selector for TransientLock__ReentrantCall()
                mstore(0x00, 0xb8021d96)
                revert(0x1c, 0x04)
            }
            tstore(TRANSIENT_LOCK_SLOT, 1)
        }
    }

    function _exitTransient() internal {
        assembly {
            tstore(TRANSIENT_LOCK_SLOT, 0)
        }
    }
}
