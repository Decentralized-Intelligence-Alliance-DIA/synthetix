pragma solidity ^0.5.16;

// Inheritance
import "./ExchangerBase.sol";

// Internal references
import "./MinimalProxyFactory.sol";
import "./interfaces/IAddressResolver.sol";
import "./interfaces/IERC20.sol";

interface IVirtualSynthInternal {
    function initialize(
        IERC20 _synth,
        IAddressResolver _resolver,
        address _recipient,
        uint _amount,
        bytes32 _currencyKey
    ) external;
}

// https://docs.synthetix.io/contracts/source/contracts/exchangerwithfeereclamationalternatives
contract ExchangerWithFeeRecAlternatives is MinimalProxyFactory, ExchangerBase {
    bytes32 public constant CONTRACT_NAME = "ExchangerWithFeeRecAlternatives";

    using SafeMath for uint;

    struct ExchangeVolumeAtPeriod {
        uint64 time;
        uint192 volume;
    }

    // To avoid 'stack too deep' errors
    struct ExchangeAtomicallyLocalVars {
        uint systemConvertedAmount;
        uint systemSourceRate;
        uint systemDestinationRate;
    }

    ExchangeVolumeAtPeriod public lastAtomicVolume;

    constructor(address _owner, address _resolver) public MinimalProxyFactory() ExchangerBase(_owner, _resolver) {}

    /* ========== ADDRESS RESOLVER CONFIGURATION ========== */

    bytes32 private constant CONTRACT_VIRTUALSYNTH_MASTERCOPY = "VirtualSynthMastercopy";

    function resolverAddressesRequired() public view returns (bytes32[] memory addresses) {
        bytes32[] memory existingAddresses = ExchangerBase.resolverAddressesRequired();
        bytes32[] memory newAddresses = new bytes32[](1);
        newAddresses[0] = CONTRACT_VIRTUALSYNTH_MASTERCOPY;
        addresses = combineArrays(existingAddresses, newAddresses);
    }

    /* ========== VIEWS ========== */

    function atomicMaxVolumePerBlock() external view returns (uint) {
        return getAtomicMaxVolumePerBlock();
    }

    function feeRateForAtomicExchange(bytes32 sourceCurrencyKey, bytes32 destinationCurrencyKey)
        external
        view
        returns (uint exchangeFeeRate)
    {
        exchangeFeeRate = _feeRateForAtomicExchange(sourceCurrencyKey, destinationCurrencyKey);
    }

    function getAmountsForAtomicExchange(
        uint sourceAmount,
        bytes32 sourceCurrencyKey,
        bytes32 destinationCurrencyKey
    )
        external
        view
        returns (
            uint amountReceived,
            uint protocolFee,
            uint exchangeFeeRate
        )
    {
        (amountReceived, protocolFee, , exchangeFeeRate, , , ) = _getAmountsForAtomicExchangeMinusFees(
            sourceAmount,
            sourceCurrencyKey,
            destinationCurrencyKey,
            bytes32(0)
        );
    }

    function getAmountsForAtomicExchangeWithTrackingCode(
        uint sourceAmount,
        bytes32 sourceCurrencyKey,
        bytes32 destinationCurrencyKey,
        bytes32 trackingCode
    )
        external
        view
        returns (
            uint amountReceived,
            uint totalFee,
            uint exchangeFeeRate
        )
    {
        uint protocolFee;
        uint partnerFee;
        (amountReceived, protocolFee, partnerFee, exchangeFeeRate, , , ) = _getAmountsForAtomicExchangeMinusFees(
            sourceAmount,
            sourceCurrencyKey,
            destinationCurrencyKey,
            trackingCode
        );
        totalFee = protocolFee.add(partnerFee);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function exchangeAtomically(
        address from,
        bytes32 sourceCurrencyKey,
        uint sourceAmount,
        bytes32 destinationCurrencyKey,
        address destinationAddress,
        bytes32 trackingCode,
        uint minAmount
    ) external onlySynthetixorSynth returns (uint amountReceived) {
        uint protocolFee;
        uint partnerFee;
        (amountReceived, protocolFee, partnerFee) = _exchangeAtomically(
            from,
            sourceCurrencyKey,
            sourceAmount,
            destinationCurrencyKey,
            destinationAddress,
            trackingCode
        );

        require(amountReceived >= minAmount, "The amount received is below the minimum amount specified.");

        _processTradingRewards(protocolFee, destinationAddress);

        if (trackingCode != bytes32(0)) {
            _emitTrackingEvent(trackingCode, destinationCurrencyKey, amountReceived, partnerFee);
        }
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _virtualSynthMastercopy() internal view returns (address) {
        return requireAndGetAddress(CONTRACT_VIRTUALSYNTH_MASTERCOPY);
    }

    function _createVirtualSynth(
        IERC20 synth,
        address recipient,
        uint amount,
        bytes32 currencyKey
    ) internal returns (IVirtualSynth) {
        // prevent inverse synths from being allowed due to purgeability
        require(currencyKey[0] != 0x69, "Cannot virtualize this synth");

        IVirtualSynthInternal vSynth =
            IVirtualSynthInternal(_cloneAsMinimalProxy(_virtualSynthMastercopy(), "Could not create new vSynth"));
        vSynth.initialize(synth, resolver, recipient, amount, currencyKey);
        emit VirtualSynthCreated(address(synth), recipient, address(vSynth), currencyKey, amount);

        return IVirtualSynth(address(vSynth));
    }

    function _exchangeAtomically(
        address from,
        bytes32 sourceCurrencyKey,
        uint sourceAmount,
        bytes32 destinationCurrencyKey,
        address destinationAddress,
        bytes32 trackingCode
    )
        internal
        returns (
            uint amountReceived,
            uint protocolFee,
            uint partnerFee
        )
    {
        ExchangeAtomicallyLocalVars memory localVars;

        _ensureCanExchange(sourceCurrencyKey, sourceAmount, destinationCurrencyKey);
        require(!exchangeRates().synthTooVolatileForAtomicExchange(sourceCurrencyKey), "Src synth too volatile");
        require(!exchangeRates().synthTooVolatileForAtomicExchange(destinationCurrencyKey), "Dest synth too volatile");

        uint sourceAmountAfterSettlement;
        sourceAmountAfterSettlement = _settleAndCalcSourceAmountRemaining(sourceAmount, from, sourceCurrencyKey);

        // If, after settlement the user has no balance left (highly unlikely), then return to prevent
        // emitting events of 0 and don't revert so as to ensure the settlement queue is emptied
        if (sourceAmountAfterSettlement == 0) {
            return (0, 0, 0);
        }

        // Note: also ensures the given synths are allowed to be atomically exchanged
        (
            amountReceived, // output amount with fee taken out (denominated in dest currency)
            protocolFee, // fee amount (denominated in dest currency)
            partnerFee, // fee amount (denominated in dest currency) // applied fee rate
            ,
            localVars.systemConvertedAmount, // current system value without fees (denominated in dest currency)
            localVars.systemSourceRate, // current system rate for src currency
            localVars.systemDestinationRate // current system rate for dest currency
        ) = _getAmountsForAtomicExchangeMinusFees(
            sourceAmountAfterSettlement,
            sourceCurrencyKey,
            destinationCurrencyKey,
            trackingCode
        );

        // SIP-65: Decentralized Circuit Breaker (checking current system rates)
        if (_exchangeRatesCircuitBroken(sourceCurrencyKey, destinationCurrencyKey)) {
            return (0, 0, 0);
        }

        // Sanity check atomic output's value against current system value (checking atomic rates)
        require(
            !exchangeCircuitBreaker().isDeviationAboveThreshold(
                localVars.systemConvertedAmount,
                amountReceived.add(protocolFee)
            ),
            "Atomic rate deviates too much"
        );

        uint sourceSusdValue;
        // Determine sUSD value of exchange
        if (sourceCurrencyKey == sUSD) {
            // Use after-settled amount as this is amount converted (not sourceAmount)
            sourceSusdValue = sourceAmountAfterSettlement;
        } else if (destinationCurrencyKey == sUSD) {
            // In this case the localVars.systemConvertedAmount would be the fee-free sUSD value of the source synth
            sourceSusdValue = localVars.systemConvertedAmount;
        } else {
            // Otherwise, convert source to sUSD value
            (uint amountReceivedInUSD, uint sUsdProtocolFee, uint sUsdPartnerFee, , , , ) =
                _getAmountsForAtomicExchangeMinusFees(sourceAmount, sourceCurrencyKey, sUSD, trackingCode);
            sourceSusdValue = amountReceivedInUSD.add(sUsdProtocolFee).add(sUsdPartnerFee);
        }

        // Check and update atomic volume limit
        _checkAndUpdateAtomicVolume(sourceSusdValue);

        // Note: We don't need to check their balance as the _convert() below will do a safe subtraction which requires
        // the subtraction to not overflow, which would happen if their balance is not sufficient.

        _convert(
            sourceCurrencyKey,
            from,
            sourceAmountAfterSettlement,
            destinationCurrencyKey,
            amountReceived,
            destinationAddress,
            false // no vsynths
        );

        // Remit the protocolFee if required
        if (protocolFee > 0) {
            // Normalize protocolFee to sUSD
            // Note: `protocolFee` is being reused to avoid stack too deep errors.
            protocolFee = exchangeRates().effectiveValue(destinationCurrencyKey, protocolFee, sUSD);

            // Remit the fee in sUSDs
            issuer().synths(sUSD).issue(feePool().FEE_ADDRESS(), protocolFee);

            // Tell the fee pool about this
            feePool().recordFeePaid(protocolFee);
        }

        if (partnerFee > 0) {
            // Normalize partnerFee to sUSD
            // Note: `partnerFee` is being reused to avoid stack too deep errors.
            partnerFee = exchangeRates().effectiveValue(destinationCurrencyKey, partnerFee, sUSD);

            payToPartner(trackingCode, from, partnerFee);
        }

        // Note: As of this point, `fee` is denominated in sUSD.

        // Note: this update of the debt snapshot will not be accurate because the atomic exchange
        // was executed with a different rate than the system rate. To be perfect, issuance data,
        // priced in system rates, should have been adjusted on the src and dest synth.
        // The debt pool is expected to be deprecated soon, and so we don't bother with being
        // perfect here. For now, an inaccuracy will slowly accrue over time with increasing atomic
        // exchange volume.
        _updateSNXIssuedDebtOnExchange(
            [sourceCurrencyKey, destinationCurrencyKey],
            [localVars.systemSourceRate, localVars.systemDestinationRate]
        );

        // Let the DApps know there was a Synth exchange
        ISynthetixInternal(address(synthetix())).emitSynthExchange(
            from,
            sourceCurrencyKey,
            sourceAmountAfterSettlement,
            destinationCurrencyKey,
            amountReceived,
            destinationAddress
        );

        // Emit separate event to track atomic exchanges
        ISynthetixInternal(address(synthetix())).emitAtomicSynthExchange(
            from,
            sourceCurrencyKey,
            sourceAmountAfterSettlement,
            destinationCurrencyKey,
            amountReceived,
            destinationAddress
        );

        // No need to persist any exchange information, as no settlement is required for atomic exchanges
    }

    function _checkAndUpdateAtomicVolume(uint sourceSusdValue) internal {
        uint currentVolume =
            uint(lastAtomicVolume.time) == block.timestamp
                ? uint(lastAtomicVolume.volume).add(sourceSusdValue)
                : sourceSusdValue;
        require(currentVolume <= getAtomicMaxVolumePerBlock(), "Surpassed volume limit");
        lastAtomicVolume.time = uint64(block.timestamp);
        lastAtomicVolume.volume = uint192(currentVolume); // Protected by volume limit check above
    }

    function _feeRateForAtomicExchange(bytes32 sourceCurrencyKey, bytes32 destinationCurrencyKey)
        internal
        view
        returns (uint)
    {
        // Get the exchange fee rate as per source and destination currencyKey
        uint baseRate = getAtomicExchangeFeeRate(sourceCurrencyKey).add(getAtomicExchangeFeeRate(destinationCurrencyKey));
        if (baseRate == 0) {
            // If no atomic rate was set, fallback to the regular exchange rate
            baseRate = getExchangeFeeRate(sourceCurrencyKey).add(getExchangeFeeRate(destinationCurrencyKey));
        }

        return baseRate;
    }

    function _getAmountsForAtomicExchangeMinusFees(
        uint sourceAmount,
        bytes32 sourceCurrencyKey,
        bytes32 destinationCurrencyKey,
        bytes32 trackingCode
    )
        internal
        view
        returns (
            uint amountReceived,
            uint protocolFee,
            uint partnerFee,
            uint exchangeFeeRate,
            uint systemConvertedAmount,
            uint systemSourceRate,
            uint systemDestinationRate
        )
    {
        uint destinationAmount;
        (destinationAmount, systemConvertedAmount, systemSourceRate, systemDestinationRate) = exchangeRates()
            .effectiveAtomicValueAndRates(sourceCurrencyKey, sourceAmount, destinationCurrencyKey);

        exchangeFeeRate = _feeRateForAtomicExchange(sourceCurrencyKey, destinationCurrencyKey);
        amountReceived = _deductFeesFromAmount(destinationAmount, exchangeFeeRate);
        protocolFee = destinationAmount.sub(amountReceived);

        if (trackingCode != bytes32(0)) {
            uint partnerFeeRate = getPartnerFeeRate(trackingCode);
            (destinationAmount, , ) = exchangeRates().effectiveValueAndRates(
                sourceCurrencyKey,
                sourceAmount,
                destinationCurrencyKey
            );
            partnerFee = destinationAmount.sub(_deductFeesFromAmount(destinationAmount, partnerFeeRate));
            amountReceived = amountReceived.sub(partnerFee);
            exchangeFeeRate = exchangeFeeRate.add(partnerFeeRate);
        }
    }

    event VirtualSynthCreated(
        address indexed synth,
        address indexed recipient,
        address vSynth,
        bytes32 currencyKey,
        uint amount
    );

    function feeRateForExchange(bytes32 sourceCurrencyKey, bytes32 destinationCurrencyKey) external view returns (uint) {
        _notImplemented();
    }

    function dynamicFeeRateForExchange(bytes32 sourceCurrencyKey, bytes32 destinationCurrencyKey)
        external
        view
        returns (uint feeRate, bool tooVolatile)
    {
        _notImplemented();
    }

    function getAmountsForExchange(
        uint sourceAmount,
        bytes32 sourceCurrencyKey,
        bytes32 destinationCurrencyKey
    )
        external
        view
        returns (
            uint amountReceived,
            uint fee,
            uint exchangeFeeRate
        )
    {
        _notImplemented();
    }

    function getAmountsForExchangeWithTrackingCode(
        uint sourceAmount,
        bytes32 sourceCurrencyKey,
        bytes32 destinationCurrencyKey,
        bytes32 trackingCode
    )
        external
        view
        returns (
            uint amountReceived,
            uint fee,
            uint exchangeFeeRate
        )
    {
        _notImplemented();
    }

    function priceDeviationThresholdFactor() external view returns (uint) {
        _notImplemented();
    }

    function waitingPeriodSecs() external view returns (uint) {
        _notImplemented();
    }

    function lastExchangeRate(bytes32 currencyKey) external view returns (uint) {
        _notImplemented();
    }

    // Mutative functions
    function exchange(
        address exchangeForAddress,
        address from,
        bytes32 sourceCurrencyKey,
        uint sourceAmount,
        bytes32 destinationCurrencyKey,
        address destinationAddress,
        bool virtualSynth,
        address rewardAddress,
        bytes32 trackingCode
    ) external returns (uint amountReceived, IVirtualSynth vSynth) {
        _notImplemented();
    }

    function settle(address from, bytes32 currencyKey)
        external
        returns (
            uint reclaimed,
            uint refunded,
            uint numEntries
        )
    {
        _notImplemented();
    }

    function suspendSynthWithInvalidRate(bytes32 currencyKey) external {
        _notImplemented();
    }
}
