pragma solidity ^0.4.2;


// Interesting parts of the ENS deed
contract Deed {
    address public owner;
    address public previousOwner;
}

// Interesting parts of the ENS registrar
contract Registrar {
    function transfer(bytes32 _hash, address newOwner);
    function entries(bytes32 _hash) constant returns (uint, Deed, uint, uint, uint);
}

contract DomainSale {
    Registrar public registrar;
    mapping (string => Sale) private sales;
    mapping (address => uint256) private balances;
    
    struct Sale {
        // The lowest auction bid that will be accepted
        uint256 reserve;
        // The lowest direct purchase price that will be accepted
        uint256 price;
        // The last bid on the auction.  0 if no bid has been made
        uint256 lastBid;
        // The address of the last bider on the auction.  0 if no bid has been made
        address lastBidder;
        // The timestamp at which this auction ends
        uint256 auctionEnds;
        // The address of the referrer who started the sale
        address startReferrer;
        // The address of the referrer who supplied the winning bid
        address bidReferrer;
    }

    //
    // Events
    //
    
    // Sent when prices are set for a name
    event Prices(string name, uint256 reserve, uint256 price);
    // Sent when a bid is placed for a name
    event Bid(string name, uint256 bid);
    // Sent when a name is transferred to a new owner
    event Transfer(string name, address from, address to, uint256 value);
    // Sent when a sale for a name is cancelled
    event Cancel(string name);

    //
    // Modifiers
    //

    // Actions that can only be undertaken by the seller of the name.
    // The owner of the name is this contract, so we use the address that
    // gave us the name to sell
    modifier onlyNameSeller(string _name) {
        Deed deed;
        (,deed,,,) = registrar.entries(sha3(_name));
        require(deed.owner() == address(this));
        require(deed.previousOwner() == msg.sender);
        _;
    }
    
    // Actions that can only be undertaken if the name sale has attracted
    // no bids.
    modifier auctionNotStarted(string _name) {
        require(sales[_name].lastBid == 0);
        _;
    }

    // Allow if the name can be bid upon
    modifier canBid(string _name) {
        require(sales[_name].reserve != 0);
        _;
    }

    // Allow if the name can be purchased
    modifier canBuy(string _name) {
        require(sales[_name].price != 0);
        _;
    }

    /**
     * @dev Constructor takes the address of a registrar,
     *      usually the .eth registrar
     */
    function DomainSale(address _registrar) {
        registrar = Registrar(_registrar);
    }
    
    //
    // Accessors for struct information
    //

    /**
     * @dev a flag set if this name can be purchased through auction
     */
    function isAuction(string _name) public constant returns (bool) {
        return sales[_name].reserve != 0;
    }

    /**
     * @dev a flag set if this name can be purchase directly
     */
    function isDirect(string _name) public constant returns (bool) {
        return sales[_name].price != 0;
    }

    /**
     * @dev a flag set if the auction has started
     */
    // TODO should this throw if this isn't an auction sale?
    function auctionStarted(string _name) public constant returns (bool) {
        return sales[_name].lastBid != 0;
    }

    /**
     * @dev the time at which the auction ends
     */
    // TODO should this throw if this isn't an auction sale?
    function auctionEnds(string _name) public constant returns (uint256) {
        return sales[_name].auctionEnds;
    }

    /**
     * @dev minimumBid is the greater of the minimum bid or the last bid + 10%.
     *      Throws if this sale does not accept bids
     */
    // TODO should this throw if this isn't an auction sale?
    function minimumBid(string _name) public constant returns (uint256) {
        Sale storage s = sales[_name];

        return s.lastBid == 0 ?
            s.reserve : 
            s.lastBid + s.lastBid / 10;
    }
    
    /**
     * @dev price is the instant purchase price.
     *      Throws if this sale does not accept an instant purchase
     */
    // TODO should this throw if this isn't a direct sale?
    function price(string _name) public constant returns (uint256) {
        Sale storage s = sales[_name];

        return s.price;
    }

    /**
     * @dev The balance available for withdrawal
     */
    function balance() public constant returns (uint256) {
        return balances[msg.sender];
    }

    //
    // Operations
    //

    /**
     * @dev start (or restart) a sale for a domain.
     *      The price is the price at which a domain can be purchased directly.
     *      The reserve is the initial lowest price for which a bid can be made.
     */
    function sell(string _name, uint256 _price, uint256 reserve, address referrer) onlyNameSeller(_name) auctionNotStarted(_name) public {
        require(_price >= reserve);
        require(_price != 0 || reserve != 0);
        Sale storage s = sales[_name];
        s.reserve = reserve; 
        s.price = _price; 
        s.startReferrer = referrer; 
        Prices(_name, reserve, _price);
    }
    
    /**
     * @dev cancel a sale for a domain.
     *      This can only happen if there have been no bids for the name.
     */
    function cancel(string _name) onlyNameSeller(_name) auctionNotStarted(_name) {
        registrar.transfer(sha3(_name), msg.sender);
        Cancel(_name);
    }

    /**
     * @dev buy a domain directly
     */
    function buy(string _name, address bidReferrer) canBuy(_name) public payable {
        Sale storage s = sales[_name];
        require(msg.value >= s.price);
        require(s.lastBid == 0); // Cannot buy if bidding is in progress (TODO: relax this?)

        // As we're here, return any funds that the sender is owed
        withdraw();
        
        // Obtain the previous owner from the deed
        Deed deed;
        (,deed,,,) = registrar.entries(sha3(_name));
        address previousOwner = deed.previousOwner();
        
        // Transfer the name
        registrar.transfer(sha3(_name), msg.sender);
        Transfer(_name, previousOwner, msg.sender, msg.value);

        // Distribute funds to referrers
        transferFunds(msg.value, previousOwner, s.startReferrer, bidReferrer);
        clearStorage(_name);
    }

    /**
     * @dev bid for a domain
     */
    function bid(string _name, address bidReferrer) canBid(_name) public payable {
        require(msg.value > minimumBid(_name));

        Sale storage s = sales[_name];
        require(now < s.auctionEnds);
        
        // As we're here, return any funds that the sender is owed
        withdraw();
        
        // Update the balance for the outbid bidder
        balances[s.lastBidder] += s.lastBid;

        s.lastBidder = msg.sender;
        s.lastBid = msg.value;
        s.auctionEnds = now + 24 hours;
        s.bidReferrer = bidReferrer;
        Bid(_name, msg.value);
    }
    
    /**
     * @dev finish an auction
     */
    function finish(string _name) public {
        Sale storage s = sales[_name];
        require(now > s.auctionEnds);

        // Obtain the previous owner from the deed
        Deed deed;
        (,deed,,,) = registrar.entries(sha3(_name));
        address previousOwner = deed.previousOwner();
        
        registrar.transfer(sha3(_name), s.lastBidder);
        Transfer(_name, previousOwner, s.lastBidder, s.lastBid);

        // Distribute funds to referrers
        transferFunds(s.lastBid, previousOwner, s.startReferrer, s.bidReferrer);
        clearStorage(_name);
    }
    
    /**
     * @dev withdraw any owned balance
     */
    function withdraw() public {
        uint256 withdrawalAmount = balances[msg.sender];
        balances[msg.sender] = 0;
        // Attempt a withdrawal
        if (withdrawalAmount > 0 && !msg.sender.send(withdrawalAmount)) {
            // Withdrawal failed; revert the balance
            balances[msg.sender] = withdrawalAmount;
        }
    }

    //
    // Internal functions
    //

    /**
     * @dev Transfer funds for a sale to the relevant parties
     */
    function transferFunds(uint256 amount, address seller, address startReferrer, address bidReferrer) internal {
        // TODO check for either referrer being 0 and redistribute accordingly
        // TODO or should we refuse 0-address referrers?  Would be simpler...
        seller.transfer(amount * 90 / 100);
        startReferrer.transfer(amount * 5 / 100);
        bidReferrer.transfer(amount * 5 / 100);
    }
    
    /**
     * @dev Clear the storage for a name
     */
    function clearStorage(string _name) internal {
        // Clear name records
        sales[_name] = Sale({
            reserve: 0, 
            price: 0, 
            lastBid:0, 
            lastBidder:0,
            auctionEnds:0,
            startReferrer: 0,
            bidReferrer: 0
        });
    }
}
