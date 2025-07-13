// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PaymentProcessor {
    address public owner;
    address public usdtContract;
    address public implementation; // قرارداد اصلی
    mapping(bytes32 => Payment) public payments;

    struct Payment {
        address proxyAddress;    // آدرس پراکسی
        uint256 payAmount;       // مقدار مورد انتظار (USDT با اعشار)
        uint256 expirationDate;  // زمان انقضا
        bool isProcessed;
    }

    event ProxyCreated(address indexed proxy, bytes32 indexed cartUuid);
    event PaymentReceived(address indexed proxy, bytes32 indexed cartUuid, uint256 amount);

    constructor(address _usdtContract, address _implementation) {
        owner = msg.sender;
        usdtContract = _usdtContract;
        implementation = _implementation;
    }

    // ایجاد پراکسی برای پرداخت جدید
    function createPaymentProxy(bytes32 cartUuid, uint256 payAmount, uint256 expirationDate) external returns (address) {
        require(msg.sender == owner, "Only owner can create payments");
        require(!payments[cartUuid].isProcessed, "Payment already processed");

        // تولید آدرس پراکسی با استفاده از CREATE2
        address proxyAddress = Clones.cloneDeterministic(implementation, cartUuid);
        payments[cartUuid] = Payment(proxyAddress, payAmount, expirationDate, false);

        // مقداردهی اولیه پراکسی با گرفتن رسپانس ارور
        (bool success, bytes memory returndata) = proxyAddress.call(
            abi.encodeWithSignature("initialize(address,bytes32)", usdtContract, cartUuid)
        );
        if (!success) {
            if (returndata.length > 68) {
                bytes memory stripped = slice(returndata, 4, returndata.length - 4);
                revert(string(stripped));
            } else {
                revert("Proxy initialization failed");
            }
        }

        emit ProxyCreated(proxyAddress, cartUuid);
        return proxyAddress;
    }

    // کمک برای slice کردن بایت‌ها (برای گرفتن پیام ری‌ورت)
    function slice(bytes memory data, uint256 start, uint256 len) internal pure returns (bytes memory) {
        bytes memory b = new bytes(len);
        for (uint i = 0; i < len; i++) {
            b[i] = data[i + start];
        }
        return b;
    }

    // علامت‌گذاری پرداخت به‌عنوان پردازش‌شده
    function markPaymentProcessed(bytes32 cartUuid) external {
        require(msg.sender == payments[cartUuid].proxyAddress, "Only proxy can mark as processed");
        require(!payments[cartUuid].isProcessed, "Payment already processed");
        payments[cartUuid].isProcessed = true;
    }

    // برداشت اضطراری
    function withdrawUSDT(uint256 amount) external {
        require(msg.sender == owner, "Only owner can withdraw");
        IERC20 usdt = IERC20(usdtContract);
        require(usdt.transfer(owner, amount), "Withdrawal failed");
    }
}

contract PaymentProxy {
    address public usdtContract;
    address public owner;
    bytes32 public cartUuid;
    bool public initialized;

    event PaymentReceived(address indexed proxy, bytes32 indexed cartUuid, uint256 amount);

    function initialize(address _usdtContract, bytes32 _cartUuid) external {
        require(!initialized, "Already initialized");
        usdtContract = _usdtContract;
        cartUuid = _cartUuid;
        owner = msg.sender;
        initialized = true;
    }

    // دریافت پرداخت
    function receivePayment() external {
        PaymentProcessor processor = PaymentProcessor(owner);
        (, uint256 payAmount, uint256 expirationDate, bool isProcessed) = processor.payments(cartUuid);
        require(!isProcessed, "Payment already processed");
        require(block.timestamp <= expirationDate, "Payment expired");

        IERC20 usdt = IERC20(usdtContract);
        uint256 amount = usdt.balanceOf(address(this));
        uint256 minAmount = (payAmount * 999) / 1000; // حداقل 0.1%
        uint256 maxAmount = (payAmount * 105) / 100;  // حداکثر 5%

        require(amount >= minAmount, "Amount too low");
        require(amount <= maxAmount, "Amount too high");
        require(usdt.transfer(owner, amount), "Transfer failed");

        processor.markPaymentProcessed(cartUuid);
        emit PaymentReceived(address(this), cartUuid, amount);
    }
}
