// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.10;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./interfaces/IVat.sol";
import "./interfaces/IPot.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IController.sol";
import "./interfaces/IFYDai.sol";
import "./helpers/Delegable.sol";
import "./helpers/DecimalMath.sol";
import "./helpers/Orchestrated.sol";


/**
 * @dev The Controller manages collateral and debt levels for all users, and it is a major user entry point for the Yield protocol.
 * Controller keeps track of a number of fyDai contracts.
 * Controller allows users to post and withdraw Chai and Weth collateral.
 * Any transactions resulting in a user weth collateral below dust are reverted.
 * Controller allows users to borrow fyDai against their Chai and Weth collateral.
 * Controller allows users to repay their fyDai debt with fyDai or with Dai.
 * Controller integrates with fyDai contracts for minting fyDai on borrowing, and burning fyDai on repaying debt with fyDai.
 * Controller relies on Treasury for all other asset transfers.
 * Controller allows orchestrated contracts to erase any amount of debt or collateral for an user. This is to be used during liquidations or during unwind.
 * Users can delegate the control of their accounts in Controllers to any address.
 */
contract Controller is IController, Orchestrated(), Delegable(), DecimalMath {
    using SafeMath for uint256;

    event Posted(bytes32 indexed collateral, address indexed user, int256 amount);
    event Borrowed(bytes32 indexed collateral, uint256 indexed maturity, address indexed user, int256 amount);

    bytes32 public constant CHAI = "CHAI";
    bytes32 public constant WETH = "ETH-A";
    uint256 public constant DUST = 50e15; // 0.05 ETH

    IVat public vat;
    IPot public pot;
    ITreasury public override treasury;

    mapping(uint256 => IFYDai) public override series;                 // FYDai series, indexed by maturity
    uint256[] public override seriesIterator;                         // We need to know all the series

    mapping(bytes32 => mapping(address => uint256)) public override posted;                        // Collateral posted by each user
    mapping(bytes32 => mapping(uint256 => mapping(address => uint256))) public override debtFYDai;  // Debt owed by each user, by series

    bool public live = true;

    /// @dev Set up addresses for vat, pot and Treasury.
    constructor (
        address treasury_,
        address[] memory fyDais

    ) public {
        treasury = ITreasury(treasury_);
        vat = treasury.vat();
        pot = treasury.pot();
        for (uint256 i = 0; i < fyDais.length; i += 1) {
            addSeries(fyDais[i]);
        }
    }

    /// @dev Modified functions only callable while the Controller is not unwinding due to a MakerDAO shutdown.
    modifier onlyLive() {
        require(live == true, "Controller: Not available during unwind");
        _;
    }

    /// @dev Only valid collateral types are Weth and Chai.
    modifier validCollateral(bytes32 collateral) {
        require(
            collateral == WETH || collateral == CHAI,
            "Controller: Unrecognized collateral"
        );
        _;
    }

    /// @dev Only series added through `addSeries` are valid.
    modifier validSeries(uint256 maturity) {
        require(
            containsSeries(maturity),
            "Controller: Unrecognized series"
        );
        _;
    }

    /// @dev Safe casting from uint256 to int256
    function toInt256(uint256 x) internal pure returns(int256) {
        require(
            x <= uint256(type(int256).max),
            "Controller: Cast overflow"
        );
        return int256(x);
    }

    /// @dev Disables post, withdraw, borrow and repay. To be called only when Treasury shuts down.
    function shutdown() public override {
        require(
            treasury.live() == false,
            "Controller: Treasury is live"
        );
        live = false;
    }

    /// @dev Return if the borrowing power for a given collateral of a user is equal or greater
    /// than its debt for the same collateral
    /// @param collateral Valid collateral type
    /// @param user Address of the user vault
    function isCollateralized(bytes32 collateral, address user) public view override returns (bool) {
        return powerOf(collateral, user) >= totalDebtDai(collateral, user);
    }

    /// @dev Return if the collateral of an user is between zero and the dust level
    /// @param collateral Valid collateral type
    /// @param user Address of the user vault
    function aboveDustOrZero(bytes32 collateral, address user) public view returns (bool) {
        uint256 postedCollateral = posted[collateral][user];
        return postedCollateral == 0 || DUST < postedCollateral;
    }

    /// @dev Return the total number of series registered
    function totalSeries() public view override returns (uint256) {
        return seriesIterator.length;
    }

    /// @dev Returns if a series has been added to the Controller.
    /// @param maturity Maturity of the series to verify.
    function containsSeries(uint256 maturity) public view override returns (bool) {
        return address(series[maturity]) != address(0);
    }

    /// @dev Adds an fyDai series to this Controller
    /// After deployment, ownership should be renounced, so that no more series can be added.
    /// @param fyDaiContract Address of the fyDai series to add.
    function addSeries(address fyDaiContract) private {
        uint256 maturity = IFYDai(fyDaiContract).maturity();
        require(
            !containsSeries(maturity),
            "Controller: Series already added"
        );
        series[maturity] = IFYDai(fyDaiContract);
        seriesIterator.push(maturity);
    }

    /// @dev Dai equivalent of an fyDai amount.
    /// After maturity, the Dai value of an fyDai grows according to either the stability fee (for WETH collateral) or the Dai Saving Rate (for Chai collateral).
    /// @param collateral Valid collateral type
    /// @param maturity Maturity of an added series
    /// @param fyDaiAmount Amount of fyDai to convert.
    /// @return Dai equivalent of an fyDai amount.
    function inDai(bytes32 collateral, uint256 maturity, uint256 fyDaiAmount)
        public view override
        validCollateral(collateral)
        returns (uint256)
    {
        IFYDai fyDai = series[maturity];
        if (fyDai.isMature()){
            if (collateral == WETH){
                return muld(fyDaiAmount, fyDai.rateGrowth());
            } else if (collateral == CHAI) {
                return muld(fyDaiAmount, fyDai.chiGrowth());
            }
        } else {
            return fyDaiAmount;
        }
    }

    /// @dev fyDai equivalent of a Dai amount.
    /// After maturity, the fyDai value of a Dai decreases according to either the stability fee (for WETH collateral) or the Dai Saving Rate (for Chai collateral).
    /// @param collateral Valid collateral type
    /// @param maturity Maturity of an added series
    /// @param daiAmount Amount of Dai to convert.
    /// @return fyDai equivalent of a Dai amount.
    function inFYDai(bytes32 collateral, uint256 maturity, uint256 daiAmount)
        public view override
        validCollateral(collateral)
        returns (uint256)
    {
        IFYDai fyDai = series[maturity];
        if (fyDai.isMature()){
            if (collateral == WETH){
                return divd(daiAmount, fyDai.rateGrowth());
            } else if (collateral == CHAI) {
                return divd(daiAmount, fyDai.chiGrowth());
            }
        } else {
            return daiAmount;
        }
    }

    /// @dev Debt in dai of an user
    /// After maturity, the Dai debt of a position grows according to either the stability fee (for WETH collateral) or the Dai Saving Rate (for Chai collateral).
    /// @param collateral Valid collateral type
    /// @param maturity Maturity of an added series
    /// @param user Address of the user vault
    /// @return Debt in dai of an user
    //
    //                        rate_now
    // debt_now = debt_mat * ----------
    //                        rate_mat
    //
    function debtDai(bytes32 collateral, uint256 maturity, address user) public view override returns (uint256) {
        return inDai(collateral, maturity, debtFYDai[collateral][maturity][user]);
    }

    /// @dev Total debt of an user across all series, in Dai
    /// The debt is summed across all series, taking into account interest on the debt after a series matures.
    /// This function loops through all maturities, limiting the contract to hundreds of maturities.
    /// @param collateral Valid collateral type
    /// @param user Address of the user vault
    /// @return Total debt of an user across all series, in Dai
    function totalDebtDai(bytes32 collateral, address user) public view override returns (uint256) {
        uint256 totalDebt;
        uint256[] memory _seriesIterator = seriesIterator;
        for (uint256 i = 0; i < _seriesIterator.length; i += 1) {
            if (debtFYDai[collateral][_seriesIterator[i]][user] > 0) {
                totalDebt = totalDebt.add(debtDai(collateral, _seriesIterator[i], user));
            }
        } // We don't expect hundreds of maturities per controller
        return totalDebt;
    }

    /// @dev Borrowing power (in dai) of a user for a specific series and collateral.
    /// @param collateral Valid collateral type
    /// @param user Address of the user vault
    /// @return Borrowing power of an user in dai.
    //
    // powerOf[user](wad) = posted[user](wad) * price()(ray)
    //
    function powerOf(bytes32 collateral, address user) public view returns (uint256) {
        // dai = price * collateral
        if (collateral == WETH){
            (,, uint256 spot,,) = vat.ilks(WETH);  // Stability fee and collateralization ratio for Weth
            return muld(posted[collateral][user], spot);
        } else if (collateral == CHAI) {
            uint256 chi = pot.chi();
            return muld(posted[collateral][user], chi);
        } else {
            revert("Controller: Invalid collateral type");
        }
    }

    /// @dev Returns the amount of collateral locked in borrowing operations.
    /// @param collateral Valid collateral type.
    /// @param user Address of the user vault.
    function locked(bytes32 collateral, address user)
        public view
        validCollateral(collateral)
        returns (uint256)
    {
        if (collateral == WETH){
            (,, uint256 spot,,) = vat.ilks(WETH);  // Stability fee and collateralization ratio for Weth
            return divdrup(totalDebtDai(collateral, user), spot);
        } else if (collateral == CHAI) {
            return divdrup(totalDebtDai(collateral, user), pot.chi());
        }
    }

    /// @dev Takes collateral assets from `from` address, and credits them to `to` collateral account.
    /// `from` can delegate to other addresses to take assets from him. Also needs to use `ERC20.approve`.
    /// Calling ERC20.approve for Treasury contract is a prerequisite to this function
    /// @param collateral Valid collateral type.
    /// @param from Wallet to take collateral from.
    /// @param to Yield vault to put the collateral in.
    /// @param amount Amount of collateral to move.
    // from --- Token ---> us(to)
    function post(bytes32 collateral, address from, address to, uint256 amount)
        public override 
        validCollateral(collateral)
        onlyHolderOrDelegate(from, "Controller: Only Holder Or Delegate")
        onlyLive
    {
        posted[collateral][to] = posted[collateral][to].add(amount);

        if (collateral == WETH){
            require(
                aboveDustOrZero(collateral, to),
                "Controller: Below dust"
            );
            treasury.pushWeth(from, amount);
        } else if (collateral == CHAI) {
            treasury.pushChai(from, amount);
        }
        
        emit Posted(collateral, to, toInt256(amount));
    }

    /// @dev Returns collateral to `to` wallet, taking it from `from` Yield vault account.
    /// `from` can delegate to other addresses to take assets from him.
    /// @param collateral Valid collateral type.
    /// @param from Yield vault to take collateral from.
    /// @param to Wallet to put the collateral in.
    /// @param amount Amount of collateral to move.
    // us(from) --- Token ---> to
    function withdraw(bytes32 collateral, address from, address to, uint256 amount)
        public override
        validCollateral(collateral)
        onlyHolderOrDelegate(from, "Controller: Only Holder Or Delegate")
        onlyLive
    {
        posted[collateral][from] = posted[collateral][from].sub(amount); // Will revert if not enough posted

        require(
            isCollateralized(collateral, from),
            "Controller: Too much debt"
        );

        if (collateral == WETH){
            require(
                aboveDustOrZero(collateral, from),
                "Controller: Below dust"
            );
            treasury.pullWeth(to, amount);
        } else if (collateral == CHAI) {
            treasury.pullChai(to, amount);
        }

        emit Posted(collateral, from, -toInt256(amount));
    }

    /// @dev Mint fyDai for a given series for wallet `to` by increasing the user debt in Yield vault `from`
    /// `from` can delegate to other addresses to borrow using his vault.
    /// The collateral needed changes according to series maturity and MakerDAO rate and chi, depending on collateral type.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param from Yield vault that gets an increased debt.
    /// @param to Wallet to put the fyDai in.
    /// @param fyDaiAmount Amount of fyDai to borrow.
    //
    // posted[user](wad) >= (debtFYDai[user](wad)) * amount (wad)) * collateralization (ray)
    //
    // us(from) --- fyDai ---> to
    // debt++
    function borrow(bytes32 collateral, uint256 maturity, address from, address to, uint256 fyDaiAmount)
        public override
        validCollateral(collateral)
        validSeries(maturity)
        onlyHolderOrDelegate(from, "Controller: Only Holder Or Delegate")
        onlyLive
    {
        IFYDai fyDai = series[maturity];

        debtFYDai[collateral][maturity][from] = debtFYDai[collateral][maturity][from].add(fyDaiAmount);

        require(
            isCollateralized(collateral, from),
            "Controller: Too much debt"
        );

        fyDai.mint(to, fyDaiAmount);
        emit Borrowed(collateral, maturity, from, toInt256(fyDaiAmount));
    }

    /// @dev Burns fyDai from `from` wallet to repay debt in a Yield Vault.
    /// User debt is decreased for the given collateral and fyDai series, in Yield vault `to`.
    /// `from` can delegate to other addresses to take fyDai from him for the repayment.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param from Wallet providing the fyDai for repayment.
    /// @param to Yield vault to repay debt for.
    /// @param fyDaiAmount Amount of fyDai to use for debt repayment.
    //
    //                                                  debt_nominal
    // debt_discounted = debt_nominal - repay_amount * ---------------
    //                                                  debt_now
    //
    // user(from) --- fyDai ---> us(to)
    // debt--
    function repayFYDai(bytes32 collateral, uint256 maturity, address from, address to, uint256 fyDaiAmount)
        public override
        validCollateral(collateral)
        validSeries(maturity)
        onlyHolderOrDelegate(from, "Controller: Only Holder Or Delegate")
        onlyLive
        returns (uint256)
    {
        uint256 toRepay = Math.min(fyDaiAmount, debtFYDai[collateral][maturity][to]);
        series[maturity].burn(from, toRepay);
        _repay(collateral, maturity, to, toRepay);
        return toRepay;
    }

    /// @dev Burns Dai from `from` wallet to repay debt in a Yield Vault.
    /// User debt is decreased for the given collateral and fyDai series, in Yield vault `to`.
    /// The amount of debt repaid changes according to series maturity and MakerDAO rate and chi, depending on collateral type.
    /// `from` can delegate to other addresses to take Dai from him for the repayment.
    /// Calling ERC20.approve for Treasury contract is a prerequisite to this function
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param from Wallet providing the Dai for repayment.
    /// @param to Yield vault to repay debt for.
    /// @param daiAmount Amount of Dai to use for debt repayment.
    //
    //                                                  debt_nominal
    // debt_discounted = debt_nominal - repay_amount * ---------------
    //                                                  debt_now
    //
    // user --- dai ---> us
    // debt--
    function repayDai(bytes32 collateral, uint256 maturity, address from, address to, uint256 daiAmount)
        public override
        validCollateral(collateral)
        validSeries(maturity)
        onlyHolderOrDelegate(from, "Controller: Only Holder Or Delegate")
        onlyLive
        returns (uint256)
    {
        uint256 toRepay = Math.min(daiAmount, debtDai(collateral, maturity, to));
        treasury.pushDai(from, toRepay);                                      // Have Treasury process the dai
        _repay(collateral, maturity, to, inFYDai(collateral, maturity, toRepay));
        return toRepay;
    }

    /// @dev Removes an amount of debt from an user's vault.
    /// Internal function.
    /// @param collateral Valid collateral type.
    /// @param maturity Maturity of an added series
    /// @param user Yield vault to repay debt for.
    /// @param fyDaiAmount Amount of fyDai to use for debt repayment.

    //
    //                                                principal
    // principal_repayment = gross_repayment * ----------------------
    //                                          principal + interest
    //    
    function _repay(bytes32 collateral, uint256 maturity, address user, uint256 fyDaiAmount) internal {
        debtFYDai[collateral][maturity][user] = debtFYDai[collateral][maturity][user].sub(fyDaiAmount);

        emit Borrowed(collateral, maturity, user, -toInt256(fyDaiAmount));
    }

    /// @dev Removes all collateral and debt for an user, for a given collateral type.
    /// This function can only be called by other Yield contracts, not users directly.
    /// @param collateral Valid collateral type.
    /// @param user Address of the user vault
    /// @return The amounts of collateral and debt removed from Controller.
    function erase(bytes32 collateral, address user)
        public override
        validCollateral(collateral)
        onlyOrchestrated("Controller: Not Authorized")
        returns (uint256, uint256)
    {
        uint256 userCollateral = posted[collateral][user];
        delete posted[collateral][user];

        uint256 userDebt;
        uint256[] memory _seriesIterator = seriesIterator;
        for (uint256 i = 0; i < _seriesIterator.length; i += 1) {
            uint256 maturity = _seriesIterator[i];
            userDebt = userDebt.add(debtDai(collateral, maturity, user)); // SafeMath shouldn't be needed
            delete debtFYDai[collateral][maturity][user];
        } // We don't expect hundreds of maturities per controller

        return (userCollateral, userDebt);
    }
}
