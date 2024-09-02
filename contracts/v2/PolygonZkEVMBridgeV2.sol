// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.8.20;

import "./lib/DepositContractV2.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import "../interfaces/IBasePolygonZkEVMGlobalExitRoot.sol";
import "../interfaces/IBridgeMessageReceiver.sol";
import "./interfaces/IPolygonZkEVMBridgeV2.sol";
import "../lib/EmergencyManager.sol";
import "../lib/GlobalExitRootLib.sol";


interface IERCXXX {
    function DOMAIN_TYPEHASH() external view returns (bytes32);
    function PERMIT_TYPEHASH() external view returns (bytes32);
    function VERSION() external view returns (string memory);
    function deploymentChainId() external view returns (uint256);
    function bridgeAddress() external view returns (address);
    function nonces(address owner) external view returns (uint256);
    function SHARE_PRICE_PRECISION() external view returns (uint256);
    function sharePrice() external view returns (uint256);
    function totalBorrowableShares() external view returns (uint256);
    function borrowBlacklist(address account) external view returns (bool);
    function maxBorrowSupplyToRealSupplyRatio() external view returns (uint256);
    function totalBorrowedSupply() external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalBorrowableSupply() external view returns (uint256);
    function currentBorrowableSupply() external view returns (uint256);
    function realTotalSupply() external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function initialize(
        address _core,
        string calldata erc20name,
        string calldata erc20symbol,
        uint8 __decimals
    ) external;

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function mint(address account, uint256 value) external;
    function burn(address account, uint256 value) external;
    function setBorrowBlacklist(address account, bool value) external;
    function setMaxBorrowSupplyToRealSupplyRatio(uint256 value) external;
    function setSharePrice(uint256 value) external;
    function mintForBorrow(address to, uint256 amount) external;
    function burnForRepay(address from, uint256 amount) external;
}

/**
 * PolygonZkEVMBridge that will be deployed on Ethereum and all Polygon rollups
 * Contract responsible to manage the token interactions with other networks
 */
contract PolygonZkEVMBridgeV2 is
    DepositContractV2,
    EmergencyManager,
    IPolygonZkEVMBridgeV2
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // Wrapped Token information struct
    struct TokenInformation {
        uint32 originNetwork;
        address originTokenAddress;
    }

    // bytes4(keccak256(bytes("permit(address,address,uint256,uint256,uint8,bytes32,bytes32)")));
    bytes4 private constant _PERMIT_SIGNATURE = 0xd505accf;

    // bytes4(keccak256(bytes("permit(address,address,uint256,uint256,bool,uint8,bytes32,bytes32)")));
    bytes4 private constant _PERMIT_SIGNATURE_DAI = 0x8fcbaf0c;

    // Mainnet identifier
    uint32 private constant _MAINNET_NETWORK_ID = 0;

    // ZkEVM identifier
    uint32 private constant _ZKEVM_NETWORK_ID = 1;

    // Leaf type asset
    uint8 private constant _LEAF_TYPE_ASSET = 0;

    // Leaf type message
    uint8 private constant _LEAF_TYPE_MESSAGE = 1;

    // Nullifier offset
    uint256 private constant _MAX_LEAFS_PER_NETWORK = 2 ** 32;

    // Indicate where's the mainnet flag bit in the global index
    uint256 private constant _GLOBAL_INDEX_MAINNET_FLAG = 2 ** 64;

    // Init code of the ercxxx wrapped token, to deploy a wrapped token the constructor parameters must be appended
    bytes public constant BASE_INIT_BYTECODE_WRAPPED_TOKEN = hex"60806040523480156200001157600080fd5b506040805160208082018352600080835283519182019093529182529060046200003c8382620000fb565b5060056200004b8282620000fb565b505050620001c7565b634e487b7160e01b600052604160045260246000fd5b600181811c908216806200007f57607f821691505b602082108103620000a057634e487b7160e01b600052602260045260246000fd5b50919050565b601f821115620000f6576000816000526020600020601f850160051c81016020861015620000d15750805b601f850160051c820191505b81811015620000f257828155600101620000dd565b5050505b505050565b81516001600160401b0381111562000117576200011762000054565b6200012f816200012884546200006a565b84620000a6565b602080601f8311600181146200016757600084156200014e5750858301515b600019600386901b1c1916600185901b178555620000f2565b600085815260208120601f198616915b82811015620001985788860151825594840194600190910190840162000177565b5085821015620001b75787850151600019600388901b60f8161c191681555b5050505050600190811b01905550565b6119c480620001d76000396000f3fe608060405234801561001057600080fd5b50600436106101fa5760003560e01c80637ecebe001161011a578063cd0d0096116100ad578063ef356a791161007c578063ef356a791461046b578063f1e30fcc14610473578063f2f4eb261461047b578063f6d2ee861461048c578063ffa1ad741461049f57600080fd5b8063cd0d009614610403578063d505accf1461040c578063dd62ed3e1461041f578063e06e4cad1461045857600080fd5b80639dc29fac116100e95780639dc29fac1461039f578063a3c573eb146103b2578063a9059cbb146103dd578063c9486d4e146103f057600080fd5b80637ecebe001461035b578063872697291461037b57806395d89b411461038457806396b17bb21461038c57600080fd5b806323b872dd116101925780633644e515116101615780633644e5151461032557806340c10f191461032d57806345fa83eb1461034057806370a082311461034857600080fd5b806323b872dd146102b357806330adf81f146102c6578063313ce567146102ed57806333e5625d1461030257600080fd5b806316b60249116101ce57806316b602491461025c57806318160ddd146102715780631e5badc31461027957806320606b701461028c57600080fd5b8062abb0f0146101ff57806305cdf8541461021b57806306fdde0314610224578063095ea7b314610239575b600080fd5b610208600e5481565b6040519081526020015b60405180910390f35b610208600d5481565b61022c6104bf565b6040516102129190611472565b61024c6102473660046114dd565b610551565b6040519015158152602001610212565b61026f61026a366004611507565b61056b565b005b610208610629565b61026f610287366004611507565b610646565b6102087f8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f81565b61024c6102c1366004611520565b6106fb565b6102087f6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c981565b60115460405160ff9091168152602001610212565b61024c61031036600461155c565b600c6020526000908152604090205460ff1681565b61020861071f565b61026f61033b3660046114dd565b61073f565b6102086107fd565b61020861035636600461155c565b61082a565b61020861036936600461155c565b60096020526000908152604090205481565b610208600a5481565b61022c610853565b61026f61039a366004611588565b610862565b61026f6103ad3660046114dd565b61093d565b6008546103c5906001600160a01b031681565b6040516001600160a01b039091168152602001610212565b61024c6103eb3660046114dd565b6109f6565b61026f6103fe3660046114dd565b610a04565b61020860065481565b61026f61041a3660046115d0565b610b39565b61020861042d36600461163a565b6001600160a01b03918216600090815260026020908152604080832093909416825291909152205490565b61026f6104663660046114dd565b610d62565b610208610e41565b610208610e58565b6000546001600160a01b03166103c5565b61026f61049a3660046116b6565b610e65565b61022c604051806040016040528060018152602001603160f81b81525081565b6060600f80546104ce90611746565b80601f01602080910402602001604051908101604052809291908181526020018280546104fa90611746565b80156105475780601f1061051c57610100808354040283529160200191610547565b820191906000526020600020905b81548152906001019060200180831161052a57829003601f168201915b5050505050905090565b60003361055f818585610f4c565b60019150505b92915050565b600054604051632474521560e21b81527fb20a487902b2a1f6494f3d3f00362a27a374ccb866b887c0a62cdf1e3225ad5360048201819052336024830152916001600160a01b0316906391d1485490604401602060405180830381865afa1580156105da573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906105fe9190611780565b6106235760405162461bcd60e51b815260040161061a9061179d565b60405180910390fd5b50600a55565b60008061063560035490565b905061064081610f59565b91505090565b600054604051632474521560e21b81527f06cc7a5825ca7b9b71735a43237a90eb8532bcd917c3f84a0b972ee7e8a2df9a60048201819052336024830152916001600160a01b0316906391d1485490604401602060405180830381865afa1580156106b5573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906106d99190611780565b6106f55760405162461bcd60e51b815260040161061a9061179d565b50600d55565b600033610709858285610f7c565b610714858585610ffa565b506001949350505050565b600060065446146107385761073346611059565b905090565b5060075490565b600054604051632474521560e21b81527f9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a660048201819052336024830152916001600160a01b0316906391d1485490604401602060405180830381865afa1580156107ae573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906107d29190611780565b6107ee5760405162461bcd60e51b815260040161061a9061179d565b6107f88383611105565b505050565b6000670de0b6b3a7640000600d54610816600b54610f59565b61082091906117d9565b61073391906117f0565b6001600160a01b03811660009081526001602052604081205461084c81610f59565b9392505050565b6060601080546104ce90611746565b600054604051632474521560e21b81527f93c39f340952e03ee4146c9b358d324d553c2ac711e1ded7b6c083f2d7b2527560048201819052336024830152916001600160a01b0316906391d1485490604401602060405180830381865afa1580156108d1573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906108f59190611780565b6109115760405162461bcd60e51b815260040161061a9061179d565b506001600160a01b03919091166000908152600c60205260409020805460ff1916911515919091179055565b600054604051632474521560e21b81527f9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a660048201819052336024830152916001600160a01b0316906391d1485490604401602060405180830381865afa1580156109ac573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906109d09190611780565b6109ec5760405162461bcd60e51b815260040161061a9061179d565b6107f8838361113f565b60003361055f818585610ffa565b600054604051632474521560e21b81527fb20a487902b2a1f6494f3d3f00362a27a374ccb866b887c0a62cdf1e3225ad5360048201819052336024830152916001600160a01b0316906391d1485490604401602060405180830381865afa158015610a73573d6000803e3d6000fd5b505050506040513d601f19601f82011682018060405250810190610a979190611780565b610ab35760405162461bcd60e51b815260040161061a9061179d565b600e54610abe6107fd565b610ac88483611812565b1115610b165760405162461bcd60e51b815260206004820152601a60248201527f4552435858583a20626f72726f77206361702072656163686564000000000000604482015260640161061a565b610b208382611812565b600e55600b54610b308585611105565b600b5550505050565b83421115610b895760405162461bcd60e51b815260206004820152601e60248201527f4552435858583a3a7065726d69743a2045787069726564207065726d69740000604482015260640161061a565b6001600160a01b038716600090815260096020526040812080547f6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9918a918a918a919086610bd683611825565b909155506040805160208101969096526001600160a01b0394851690860152929091166060840152608083015260a082015260c0810186905260e0016040516020818303038152906040528051906020012090506000610c3461071f565b60405161190160f01b602082015260228101919091526042810183905260620160408051601f198184030181528282528051602091820120600080855291840180845281905260ff89169284019290925260608301879052608083018690529092509060019060a0016020604051602081039080840390855afa158015610cbf573d6000803e3d6000fd5b5050604051601f1901519150506001600160a01b03811615801590610cf55750896001600160a01b0316816001600160a01b0316145b610d4b5760405162461bcd60e51b815260206004820152602160248201527f4552435858583a3a7065726d69743a20496e76616c6964207369676e617475726044820152606560f81b606482015260840161061a565b610d568a8a8a610f4c565b50505050505050505050565b600054604051632474521560e21b81527fb20a487902b2a1f6494f3d3f00362a27a374ccb866b887c0a62cdf1e3225ad5360048201819052336024830152916001600160a01b0316906391d1485490604401602060405180830381865afa158015610dd1573d6000803e3d6000fd5b505050506040513d601f19601f82011682018060405250810190610df59190611780565b610e115760405162461bcd60e51b815260040161061a9061179d565b600e5480831115610e26576000600e55610e34565b610e30838261183e565b600e555b600b54610b30858561113f565b6000600e54610e4e610629565b610733919061183e565b6000600e54610e4e6107fd565b6000546001600160a01b031615610e7e57610e7e611851565b6001600160a01b038616610e9457610e94611851565b600f610ea18587836118cd565b506010610eaf8385836118cd565b506011805460ff191660ff8316179055600080546001600160a01b0319166001600160a01b038816179055670de0b6b3a7640000600a819055600d5560008052600c6020527f13649b2456f1b42fef0f0040b3aaeabcd21a76a0f3f5defd4f583839455116e8805460ff19166001179055466006819055610f2f90611059565b6007555050600880546001600160a01b0319163317905550505050565b6107f88383836001611175565b6000670de0b6b3a7640000600a5483610f7291906117d9565b61056591906117f0565b6001600160a01b038381166000908152600260209081526040808320938616835292905220546000198114610ff45781811015610fe557604051637dc7a0d960e11b81526001600160a01b0384166004820152602481018290526044810183905260640161061a565b610ff484848484036000611175565b50505050565b6001600160a01b03831661102457604051634b637e8f60e11b81526000600482015260240161061a565b6001600160a01b03821661104e5760405163ec442f0560e01b81526000600482015260240161061a565b6107f883838361124a565b60007f8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f6110846104bf565b805160209182012060408051808201825260018152603160f81b90840152805192830193909352918101919091527fc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc66060820152608081018390523060a082015260c001604051602081830303815290604052805190602001209050919050565b6001600160a01b03821661112f5760405163ec442f0560e01b81526000600482015260240161061a565b61113b6000838361124a565b5050565b6001600160a01b03821661116957604051634b637e8f60e11b81526000600482015260240161061a565b61113b8260008361124a565b6001600160a01b03841661119f5760405163e602df0560e01b81526000600482015260240161061a565b6001600160a01b0383166111c957604051634a1406b160e11b81526000600482015260240161061a565b6001600160a01b0380851660009081526002602090815260408083209387168352929052208290558015610ff457826001600160a01b0316846001600160a01b03167f8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b9258460405161123c91815260200190565b60405180910390a350505050565b60006112558261131f565b6001600160a01b0385166000908152600c602052604090205490915060ff1615801561129957506001600160a01b0383166000908152600c602052604090205460ff165b156112b65780600b60008282546112b0919061183e565b90915550505b6001600160a01b0384166000908152600c602052604090205460ff1680156112f757506001600160a01b0383166000908152600c602052604090205460ff16155b156113145780600b600082825461130e9190611812565b90915550505b610ff4848483611348565b6000600a5460000361133357506000919050565b600a54610f72670de0b6b3a7640000846117d9565b6001600160a01b0383166113735780600360008282546113689190611812565b909155506113e59050565b6001600160a01b038316600090815260016020526040902054818110156113c65760405163391434e360e21b81526001600160a01b0385166004820152602481018290526044810183905260640161061a565b6001600160a01b03841660009081526001602052604090209082900390555b6001600160a01b03821661140157600380548290039055611420565b6001600160a01b03821660009081526001602052604090208054820190555b816001600160a01b0316836001600160a01b03167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef8360405161146591815260200190565b60405180910390a3505050565b60006020808352835180602085015260005b818110156114a057858101830151858201604001528201611484565b506000604082860101526040601f19601f8301168501019250505092915050565b80356001600160a01b03811681146114d857600080fd5b919050565b600080604083850312156114f057600080fd5b6114f9836114c1565b946020939093013593505050565b60006020828403121561151957600080fd5b5035919050565b60008060006060848603121561153557600080fd5b61153e846114c1565b925061154c602085016114c1565b9150604084013590509250925092565b60006020828403121561156e57600080fd5b61084c826114c1565b801515811461158557600080fd5b50565b6000806040838503121561159b57600080fd5b6115a4836114c1565b915060208301356115b481611577565b809150509250929050565b803560ff811681146114d857600080fd5b600080600080600080600060e0888a0312156115eb57600080fd5b6115f4886114c1565b9650611602602089016114c1565b9550604088013594506060880135935061161e608089016115bf565b925060a0880135915060c0880135905092959891949750929550565b6000806040838503121561164d57600080fd5b611656836114c1565b9150611664602084016114c1565b90509250929050565b60008083601f84011261167f57600080fd5b50813567ffffffffffffffff81111561169757600080fd5b6020830191508360208285010111156116af57600080fd5b9250929050565b600080600080600080608087890312156116cf57600080fd5b6116d8876114c1565b9550602087013567ffffffffffffffff808211156116f557600080fd5b6117018a838b0161166d565b9097509550604089013591508082111561171a57600080fd5b5061172789828a0161166d565b909450925061173a9050606088016115bf565b90509295509295509295565b600181811c9082168061175a57607f821691505b60208210810361177a57634e487b7160e01b600052602260045260246000fd5b50919050565b60006020828403121561179257600080fd5b815161084c81611577565b6020808252600c908201526b15539055551213d49256915160a21b604082015260600190565b634e487b7160e01b600052601160045260246000fd5b8082028115828204841417610565576105656117c3565b60008261180d57634e487b7160e01b600052601260045260246000fd5b500490565b80820180821115610565576105656117c3565b600060018201611837576118376117c3565b5060010190565b81810381811115610565576105656117c3565b634e487b7160e01b600052600160045260246000fd5b634e487b7160e01b600052604160045260246000fd5b601f8211156107f8576000816000526020600020601f850160051c810160208610156118a65750805b601f850160051c820191505b818110156118c5578281556001016118b2565b505050505050565b67ffffffffffffffff8311156118e5576118e5611867565b6118f9836118f38354611746565b8361187d565b6000601f84116001811461192d57600085156119155750838201355b600019600387901b1c1916600186901b178355611987565b600083815260209020601f19861690835b8281101561195e578685013582556020948501946001909201910161193e565b508682101561197b5760001960f88860031b161c19848701351681555b505060018560011b0183555b505050505056fea2646970667358221220b5d21b00bfc9c873899c9ba500b07b98204bcd96f89b482b6ba779670f88781764736f6c63430008170033";

    // Network identifier
    uint32 public networkID;

    // Global Exit Root address
    IBasePolygonZkEVMGlobalExitRoot public globalExitRootManager;

    // Last updated deposit count to the global exit root manager
    uint32 public lastUpdatedDepositCount;

    // Leaf index --> claimed bit map
    mapping(uint256 => uint256) public claimedBitMap;

    // keccak256(OriginNetwork || tokenAddress) --> Wrapped token address
    mapping(bytes32 => address) public tokenInfoToWrappedToken;

    // Wrapped token Address --> Origin token information
    mapping(address => TokenInformation) public wrappedTokenToTokenInfo;

    // Rollup manager address, previously PolygonZkEVM
    /// @custom:oz-renamed-from polygonZkEVMaddress
    address public polygonRollupManager;

    // Native address
    address public gasTokenAddress;

    // Native address
    uint32 public gasTokenNetwork;

    // Gas token metadata
    bytes public gasTokenMetadata;

    // WETH address
    IERCXXX public WETHToken;

    address public core;

    bytes public ercxxxBytecode;

    /**
     * @dev Emitted when bridge assets or messages to another network
     */
    event BridgeEvent(
        uint8 leafType,
        uint32 originNetwork,
        address originAddress,
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amount,
        bytes metadata,
        uint32 depositCount
    );

    /**
     * @dev Emitted when a claim is done from another network
     */
    event ClaimEvent(
        uint256 globalIndex,
        uint32 originNetwork,
        address originAddress,
        address destinationAddress,
        uint256 amount
    );

    /**
     * @dev Emitted when a new wrapped token is created
     */
    event NewWrappedToken(
        uint32 originNetwork,
        address originTokenAddress,
        address wrappedTokenAddress,
        bytes metadata
    );

    /**
     * Disable initalizers on the implementation following the best practices
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @param _networkID networkID
     * @param _gasTokenAddress gas token address
     * @param _gasTokenNetwork gas token network
     * @param _globalExitRootManager global exit root manager address
     * @param _polygonRollupManager polygonZkEVM address
     * @notice The value of `_polygonRollupManager` on the L2 deployment of the contract will be address(0), so
     * emergency state is not possible for the L2 deployment of the bridge, intentionally
     * @param _gasTokenMetadata Abi encoded gas token metadata
     */
    function initialize(
        uint32 _networkID,
        address _gasTokenAddress,
        uint32 _gasTokenNetwork,
        IBasePolygonZkEVMGlobalExitRoot _globalExitRootManager,
        address _polygonRollupManager,
        bytes memory _gasTokenMetadata
    ) external virtual initializer {
        networkID = _networkID;
        globalExitRootManager = _globalExitRootManager;
        polygonRollupManager = _polygonRollupManager;

        // Set gas token
        if (_gasTokenAddress == address(0)) {
            // Gas token will be ether
            if (_gasTokenNetwork != 0) {
                revert GasTokenNetworkMustBeZeroOnEther();
            }
            // WETHToken, gasTokenAddress and gasTokenNetwork will be 0
            // gasTokenMetadata will be empty
        } else {
            // Gas token will be an erc20
            gasTokenAddress = _gasTokenAddress;
            gasTokenNetwork = _gasTokenNetwork;
            gasTokenMetadata = _gasTokenMetadata;

             // Create a wrapped token for WETH, with salt == 0
            WETHToken = _deployWrappedToken(
                0, // salt
                "Wrapped Ether",
                "WETH", 
                18);
        }

        // Initialize OZ contracts
        __ReentrancyGuard_init();
    }

    modifier onlyRollupManager() {
        if (polygonRollupManager != msg.sender) {
            revert OnlyRollupManager();
        }
        _;
    }

    /**
     * @notice Deposit add a new leaf to the merkle tree
     * note If this function is called with a reentrant token, it would be possible to `claimTokens` in the same call
     * Reducing the supply of tokens on this contract, and actually locking tokens in the contract.
     * Therefore we recommend to third parties bridges that if they do implement reentrant call of `beforeTransfer` of some reentrant tokens
     * do not call any external address in that case
     * note User/UI must be aware of the existing/available networks when choosing the destination network
     * @param destinationNetwork Network destination
     * @param destinationAddress Address destination
     * @param amount Amount of tokens
     * @param token Token address, 0 address is reserved for ether
     * @param forceUpdateGlobalExitRoot Indicates if the new global exit root is updated or not
     * @param permitData Raw data of the call `permit` of the token
     */
    function bridgeAsset(
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amount,
        address token,
        bool forceUpdateGlobalExitRoot,
        bytes calldata permitData
    ) public payable virtual ifNotEmergencyState nonReentrant {
        if (destinationNetwork == networkID) {
            revert DestinationNetworkInvalid();
        }

        address originTokenAddress;
        uint32 originNetwork;
        bytes memory metadata;
        uint256 leafAmount = amount;

        if (token == address(0)) {
            // Check gas token transfer
            if (msg.value != amount) {
                revert AmountDoesNotMatchMsgValue();
            }

            // Set gas token parameters
            originNetwork = gasTokenNetwork;
            originTokenAddress = gasTokenAddress;
            metadata = gasTokenMetadata;
        } else {
            // Check msg.value is 0 if tokens are bridged
            if (msg.value != 0) {
                revert MsgValueNotZero();
            }

            // Check if it's WETH, this only applies on L2 networks with gasTokens
            // In case ether is the native token, WETHToken will be 0, and the address 0 is already checked
            if (token == address(WETHToken)) {
                // Burn tokens
                IERCXXX(token).burn(msg.sender, amount);

                // Both origin network and originTokenAddress will be 0
                // Metadata will be empty
            } else {
                TokenInformation memory tokenInfo = wrappedTokenToTokenInfo[
                    token
                ];

                if (tokenInfo.originTokenAddress != address(0)) {
                    // The token is a wrapped token from another network

                    // Burn tokens
                    IERCXXX(token).burn(msg.sender, amount);

                    originTokenAddress = tokenInfo.originTokenAddress;
                    originNetwork = tokenInfo.originNetwork;
                } else {
                    // Use permit if any
                    if (permitData.length != 0) {
                        _permit(token, amount, permitData);
                    }

                    // In order to support fee tokens check the amount received, not the transferred
                    uint256 balanceBefore = IERC20Upgradeable(token).balanceOf(
                        address(this)
                    );
                    IERC20Upgradeable(token).safeTransferFrom(
                        msg.sender,
                        address(this),
                        amount
                    );
                    uint256 balanceAfter = IERC20Upgradeable(token).balanceOf(
                        address(this)
                    );

                    // Override leafAmount with the received amount
                    leafAmount = balanceAfter - balanceBefore;

                    originTokenAddress = token;
                    originNetwork = networkID;
                }
                // Encode metadata
                metadata = getTokenMetadata(token);
            }
        }

        emit BridgeEvent(
            _LEAF_TYPE_ASSET,
            originNetwork,
            originTokenAddress,
            destinationNetwork,
            destinationAddress,
            leafAmount,
            metadata,
            uint32(depositCount)
        );

        _addLeaf(
            getLeafValue(
                _LEAF_TYPE_ASSET,
                originNetwork,
                originTokenAddress,
                destinationNetwork,
                destinationAddress,
                leafAmount,
                keccak256(metadata)
            )
        );

        // Update the new root to the global exit root manager if set by the user
        if (forceUpdateGlobalExitRoot) {
            _updateGlobalExitRoot();
        }
    }

    /**
     * @notice Bridge message and send ETH value
     * note User/UI must be aware of the existing/available networks when choosing the destination network
     * @param destinationNetwork Network destination
     * @param destinationAddress Address destination
     * @param forceUpdateGlobalExitRoot Indicates if the new global exit root is updated or not
     * @param metadata Message metadata
     */
    function bridgeMessage(
        uint32 destinationNetwork,
        address destinationAddress,
        bool forceUpdateGlobalExitRoot,
        bytes calldata metadata
    ) external payable ifNotEmergencyState {
        // If exist a gas token, only allow call this function without value
        if (msg.value != 0 && address(WETHToken) != address(0)) {
            revert NoValueInMessagesOnGasTokenNetworks();
        }

        _bridgeMessage(
            destinationNetwork,
            destinationAddress,
            msg.value,
            forceUpdateGlobalExitRoot,
            metadata
        );
    }

    /**
     * @notice Bridge message and send ETH value
     * note User/UI must be aware of the existing/available networks when choosing the destination network
     * @param destinationNetwork Network destination
     * @param destinationAddress Address destination
     * @param amountWETH Amount of WETH tokens
     * @param forceUpdateGlobalExitRoot Indicates if the new global exit root is updated or not
     * @param metadata Message metadata
     */
    function bridgeMessageWETH(
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amountWETH,
        bool forceUpdateGlobalExitRoot,
        bytes calldata metadata
    ) external ifNotEmergencyState {
        // If native token is ether, disable this function
        if (address(WETHToken) == address(0)) {
            revert NativeTokenIsEther();
        }

        // Burn wETH tokens
        WETHToken.burn(msg.sender, amountWETH);

        _bridgeMessage(
            destinationNetwork,
            destinationAddress,
            amountWETH,
            forceUpdateGlobalExitRoot,
            metadata
        );
    }

    /**
     * @notice Bridge message and send ETH value
     * @param destinationNetwork Network destination
     * @param destinationAddress Address destination
     * @param amountEther Amount of ether along with the message
     * @param forceUpdateGlobalExitRoot Indicates if the new global exit root is updated or not
     * @param metadata Message metadata
     */
    function _bridgeMessage(
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amountEther,
        bool forceUpdateGlobalExitRoot,
        bytes calldata metadata
    ) internal {
        if (destinationNetwork == networkID) {
            revert DestinationNetworkInvalid();
        }

        emit BridgeEvent(
            _LEAF_TYPE_MESSAGE,
            networkID,
            msg.sender,
            destinationNetwork,
            destinationAddress,
            amountEther,
            metadata,
            uint32(depositCount)
        );

        _addLeaf(
            getLeafValue(
                _LEAF_TYPE_MESSAGE,
                networkID,
                msg.sender,
                destinationNetwork,
                destinationAddress,
                amountEther,
                keccak256(metadata)
            )
        );

        // Update the new root to the global exit root manager if set by the user
        if (forceUpdateGlobalExitRoot) {
            _updateGlobalExitRoot();
        }
    }

    /**
     * @notice Verify merkle proof and withdraw tokens/ether
     * @param smtProofLocalExitRoot Smt proof to proof the leaf against the network exit root
     * @param smtProofRollupExitRoot Smt proof to proof the rollupLocalExitRoot against the rollups exit root
     * @param globalIndex Global index is defined as:
     * | 191 bits |    1 bit     |   32 bits   |     32 bits    |
     * |    0     |  mainnetFlag | rollupIndex | localRootIndex |
     * note that only the rollup index will be used only in case the mainnet flag is 0
     * note that global index do not assert the unused bits to 0.
     * This means that when synching the events, the globalIndex must be decoded the same way that in the Smart contract
     * to avoid possible synch attacks
     * @param mainnetExitRoot Mainnet exit root
     * @param rollupExitRoot Rollup exit root
     * @param originNetwork Origin network
     * @param originTokenAddress  Origin token address, 0 address is reserved for ether
     * @param destinationNetwork Network destination
     * @param destinationAddress Address destination
     * @param amount Amount of tokens
     * @param metadata Abi encoded metadata if any, empty otherwise
     */
    function claimAsset(
        bytes32[_DEPOSIT_CONTRACT_TREE_DEPTH] calldata smtProofLocalExitRoot,
        bytes32[_DEPOSIT_CONTRACT_TREE_DEPTH] calldata smtProofRollupExitRoot,
        uint256 globalIndex,
        bytes32 mainnetExitRoot,
        bytes32 rollupExitRoot,
        uint32 originNetwork,
        address originTokenAddress,
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amount,
        bytes calldata metadata
    ) external ifNotEmergencyState {
        // Destination network must be this networkID
        if (destinationNetwork != networkID) {
            revert DestinationNetworkInvalid();
        }

        // Verify leaf exist and it does not have been claimed
        _verifyLeaf(
            smtProofLocalExitRoot,
            smtProofRollupExitRoot,
            globalIndex,
            mainnetExitRoot,
            rollupExitRoot,
            getLeafValue(
                _LEAF_TYPE_ASSET,
                originNetwork,
                originTokenAddress,
                destinationNetwork,
                destinationAddress,
                amount,
                keccak256(metadata)
            )
        );

        // Transfer funds
        if (originTokenAddress == address(0)) {
            if (address(WETHToken) == address(0)) {
                // Ether is the native token
                /* solhint-disable avoid-low-level-calls */
                (bool success, ) = destinationAddress.call{value: amount}(
                    new bytes(0)
                );
                if (!success) {
                    revert EtherTransferFailed();
                }
            } else {
                // Claim wETH
                WETHToken.mint(destinationAddress, amount);
            }
        } else {
            // Check if it's gas token
            if (
                originTokenAddress == gasTokenAddress &&
                gasTokenNetwork == originNetwork
            ) {
                // Transfer gas token
                /* solhint-disable avoid-low-level-calls */
                (bool success, ) = destinationAddress.call{value: amount}(
                    new bytes(0)
                );
                if (!success) {
                    revert EtherTransferFailed();
                }
            } else {
                // Transfer tokens
                if (originNetwork == networkID) {
                    // The token is an ERC20 from this network
                    IERC20Upgradeable(originTokenAddress).safeTransfer(
                        destinationAddress,
                        amount
                    );
                } else {
                    // The tokens is not from this network
                    // Create a wrapper for the token if not exist yet
                    bytes32 tokenInfoHash = keccak256(
                        abi.encodePacked(originNetwork, originTokenAddress)
                    );
                    address wrappedToken = tokenInfoToWrappedToken[
                        tokenInfoHash
                    ];

                    if (wrappedToken == address(0)) {
                        // Get ERC20 metadata

                        (string memory name, string memory symbol, uint8 decimals) = abi.decode(metadata, (string, string, uint8));
                        // Create a new wrapped erc20 using create2
                        IERCXXX newWrappedToken = _deployWrappedToken(
                            tokenInfoHash,
                            name,
                            symbol,
                            decimals
                        );

                        // Mint tokens for the destination address
                        newWrappedToken.mint(destinationAddress, amount);

                        // Create mappings
                        tokenInfoToWrappedToken[tokenInfoHash] = address(
                            newWrappedToken
                        );

                        wrappedTokenToTokenInfo[
                            address(newWrappedToken)
                        ] = TokenInformation(originNetwork, originTokenAddress);

                        emit NewWrappedToken(
                            originNetwork,
                            originTokenAddress,
                            address(newWrappedToken),
                            metadata
                        );
                    } else {
                        // Use the existing wrapped erc20
                        IERCXXX(wrappedToken).mint(
                            destinationAddress,
                            amount
                        );
                    }
                }
            }
        }

        // ONLY ON KRED L2
        if(destinationNetwork == 1) {
            // check receiver balance, if less than 0.5 KRED, send 1 KRED
            if(destinationAddress.balance < 0.5e18) {
                // send 1 KRED
                /* solhint-disable avoid-low-level-calls */
                (bool success, ) = destinationAddress.call{value: 1e18}(
                    new bytes(0)
                );
                if (!success) {
                    revert EtherTransferFailed();
                }
            }
        }

        emit ClaimEvent(
            globalIndex,
            originNetwork,
            originTokenAddress,
            destinationAddress,
            amount
        );
    }

    /**
     * @notice Verify merkle proof and execute message
     * If the receiving address is an EOA, the call will result as a success
     * Which means that the amount of ether will be transferred correctly, but the message
     * will not trigger any execution
     * @param smtProofLocalExitRoot Smt proof to proof the leaf against the exit root
     * @param smtProofRollupExitRoot Smt proof to proof the rollupLocalExitRoot against the rollups exit root
     * @param globalIndex Global index is defined as:
     * | 191 bits |    1 bit     |   32 bits   |     32 bits    |
     * |    0     |  mainnetFlag | rollupIndex | localRootIndex |
     * note that only the rollup index will be used only in case the mainnet flag is 0
     * note that global index do not assert the unused bits to 0.
     * This means that when synching the events, the globalIndex must be decoded the same way that in the Smart contract
     * to avoid possible synch attacks
     * @param mainnetExitRoot Mainnet exit root
     * @param rollupExitRoot Rollup exit root
     * @param originNetwork Origin network
     * @param originAddress Origin address
     * @param destinationNetwork Network destination
     * @param destinationAddress Address destination
     * @param amount message value
     * @param metadata Abi encoded metadata if any, empty otherwise
     */
    function claimMessage(
        bytes32[_DEPOSIT_CONTRACT_TREE_DEPTH] calldata smtProofLocalExitRoot,
        bytes32[_DEPOSIT_CONTRACT_TREE_DEPTH] calldata smtProofRollupExitRoot,
        uint256 globalIndex,
        bytes32 mainnetExitRoot,
        bytes32 rollupExitRoot,
        uint32 originNetwork,
        address originAddress,
        uint32 destinationNetwork,
        address destinationAddress,
        uint256 amount,
        bytes calldata metadata
    ) external ifNotEmergencyState {
        // Destination network must be this networkID
        if (destinationNetwork != networkID) {
            revert DestinationNetworkInvalid();
        }

        // Verify leaf exist and it does not have been claimed
        _verifyLeaf(
            smtProofLocalExitRoot,
            smtProofRollupExitRoot,
            globalIndex,
            mainnetExitRoot,
            rollupExitRoot,
            getLeafValue(
                _LEAF_TYPE_MESSAGE,
                originNetwork,
                originAddress,
                destinationNetwork,
                destinationAddress,
                amount,
                keccak256(metadata)
            )
        );

        // Execute message
        bool success;
        if (address(WETHToken) == address(0)) {
            // Native token is ether
            // Transfer ether
            /* solhint-disable avoid-low-level-calls */
            (success, ) = destinationAddress.call{value: amount}(
                abi.encodeCall(
                    IBridgeMessageReceiver.onMessageReceived,
                    (originAddress, originNetwork, metadata)
                )
            );
        } else {
            // Mint wETH tokens
            WETHToken.mint(destinationAddress, amount);

            // Execute message
            /* solhint-disable avoid-low-level-calls */
            (success, ) = destinationAddress.call(
                abi.encodeCall(
                    IBridgeMessageReceiver.onMessageReceived,
                    (originAddress, originNetwork, metadata)
                )
            );
        }

        if (!success) {
            revert MessageFailed();
        }

        emit ClaimEvent(
            globalIndex,
            originNetwork,
            originAddress,
            destinationAddress,
            amount
        );
    }

    /**
     * @notice Returns the precalculated address of a wrapper using the token information
     * Note Updating the metadata of a token is not supported.
     * Since the metadata has relevance in the address deployed, this function will not return a valid
     * wrapped address if the metadata provided is not the original one.
     * @param originNetwork Origin network
     * @param originTokenAddress Origin token address, 0 address is reserved for ether
     * @param name Name of the token
     * @param symbol Symbol of the token
     * @param decimals Decimals of the token
     */
    function precalculatedWrapperAddress(
        uint32 originNetwork,
        address originTokenAddress,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) public view returns (address) {
        bytes32 salt = keccak256(
            abi.encodePacked(originNetwork, originTokenAddress)
        );

        bytes memory bytecode = ercxxxBytecode.length == 0 ? abi.encodePacked(
                        BASE_INIT_BYTECODE_WRAPPED_TOKEN,
                        abi.encode(name, symbol, decimals)
                    ) : ercxxxBytecode;

        bytes32 hashCreate2 = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(bytecode)
            )
        );

        // Last 20 bytes of hash to address
        return address(uint160(uint256(hashCreate2)));
    }

    /**
     * @notice Returns the address of a wrapper using the token information if already exist
     * @param originNetwork Origin network
     * @param originTokenAddress Origin token address, 0 address is reserved for ether
     */
    function getTokenWrappedAddress(
        uint32 originNetwork,
        address originTokenAddress
    ) external view returns (address) {
        return
            tokenInfoToWrappedToken[
                keccak256(abi.encodePacked(originNetwork, originTokenAddress))
            ];
    }

    /**
     * @notice Function to activate the emergency state
     " Only can be called by the Polygon ZK-EVM in extreme situations
     */
    function activateEmergencyState() external onlyRollupManager {
        _activateEmergencyState();
    }

    /**
     * @notice Function to deactivate the emergency state
     " Only can be called by the Polygon ZK-EVM
     */
    function deactivateEmergencyState() external onlyRollupManager {
        _deactivateEmergencyState();
    }

    /**
     * @notice Verify leaf and checks that it has not been claimed
     * @param smtProofLocalExitRoot Smt proof
     * @param smtProofRollupExitRoot Smt proof
     * @param globalIndex Index of the leaf
     * @param mainnetExitRoot Mainnet exit root
     * @param rollupExitRoot Rollup exit root
     * @param leafValue leaf value
     */
    function _verifyLeaf(
        bytes32[_DEPOSIT_CONTRACT_TREE_DEPTH] calldata smtProofLocalExitRoot,
        bytes32[_DEPOSIT_CONTRACT_TREE_DEPTH] calldata smtProofRollupExitRoot,
        uint256 globalIndex,
        bytes32 mainnetExitRoot,
        bytes32 rollupExitRoot,
        bytes32 leafValue
    ) internal {
        // Check blockhash where the global exit root was set
        // Note that previusly timestamps were setted, since in only checked if != 0 it's ok
        uint256 blockHashGlobalExitRoot = globalExitRootManager
            .globalExitRootMap(
                GlobalExitRootLib.calculateGlobalExitRoot(
                    mainnetExitRoot,
                    rollupExitRoot
                )
            );

        // check that this global exit root exist
        if (blockHashGlobalExitRoot == 0) {
            revert GlobalExitRootInvalid();
        }

        uint32 leafIndex;
        uint32 sourceBridgeNetwork;

        // Get origin network from global index
        if (globalIndex & _GLOBAL_INDEX_MAINNET_FLAG != 0) {
            // the network is mainnet, therefore sourceBridgeNetwork is 0

            // Last 32 bits are leafIndex
            leafIndex = uint32(globalIndex);

            if (
                !verifyMerkleProof(
                    leafValue,
                    smtProofLocalExitRoot,
                    leafIndex,
                    mainnetExitRoot
                )
            ) {
                revert InvalidSmtProof();
            }
        } else {
            // the network is a rollup, therefore sourceBridgeNetwork must be decoded
            uint32 indexRollup = uint32(globalIndex >> 32);
            sourceBridgeNetwork = indexRollup + 1;

            // Last 32 bits are leafIndex
            leafIndex = uint32(globalIndex);

            // Verify merkle proof agains rollup exit root
            if (
                !verifyMerkleProof(
                    calculateRoot(leafValue, smtProofLocalExitRoot, leafIndex),
                    smtProofRollupExitRoot,
                    indexRollup,
                    rollupExitRoot
                )
            ) {
                revert InvalidSmtProof();
            }
        }

        // Set and check nullifier
        _setAndCheckClaimed(leafIndex, sourceBridgeNetwork);
    }

    /**
     * @notice Function to check if an index is claimed or not
     * @param leafIndex Index
     * @param sourceBridgeNetwork Origin network
     */
    function isClaimed(
        uint32 leafIndex,
        uint32 sourceBridgeNetwork
    ) external view returns (bool) {
        uint256 globalIndex;

        // For consistency with the previous setted nullifiers
        if (
            networkID == _MAINNET_NETWORK_ID &&
            sourceBridgeNetwork == _ZKEVM_NETWORK_ID
        ) {
            globalIndex = uint256(leafIndex);
        } else {
            globalIndex =
                uint256(leafIndex) +
                uint256(sourceBridgeNetwork) *
                _MAX_LEAFS_PER_NETWORK;
        }
        (uint256 wordPos, uint256 bitPos) = _bitmapPositions(globalIndex);
        uint256 mask = (1 << bitPos);
        return (claimedBitMap[wordPos] & mask) == mask;
    }

    /**
     * @notice Function to check that an index is not claimed and set it as claimed
     * @param leafIndex Index
     * @param sourceBridgeNetwork Origin network
     */
    function _setAndCheckClaimed(
        uint32 leafIndex,
        uint32 sourceBridgeNetwork
    ) private {
        uint256 globalIndex;

        // For consistency with the previous setted nullifiers
        if (
            networkID == _MAINNET_NETWORK_ID &&
            sourceBridgeNetwork == _ZKEVM_NETWORK_ID
        ) {
            globalIndex = uint256(leafIndex);
        } else {
            globalIndex =
                uint256(leafIndex) +
                uint256(sourceBridgeNetwork) *
                _MAX_LEAFS_PER_NETWORK;
        }
        (uint256 wordPos, uint256 bitPos) = _bitmapPositions(globalIndex);
        uint256 mask = 1 << bitPos;
        uint256 flipped = claimedBitMap[wordPos] ^= mask;
        if (flipped & mask == 0) {
            revert AlreadyClaimed();
        }
    }

    /**
     * @notice Function to update the globalExitRoot if the last deposit is not submitted
     */
    function updateGlobalExitRoot() external {
        if (lastUpdatedDepositCount < depositCount) {
            _updateGlobalExitRoot();
        }
    }

    /**
     * @notice Function to update the globalExitRoot
     */
    function _updateGlobalExitRoot() internal {
        lastUpdatedDepositCount = uint32(depositCount);
        globalExitRootManager.updateExitRoot(getRoot());
    }

    /**
     * @notice Function decode an index into a wordPos and bitPos
     * @param index Index
     */
    function _bitmapPositions(
        uint256 index
    ) private pure returns (uint256 wordPos, uint256 bitPos) {
        wordPos = uint248(index >> 8);
        bitPos = uint8(index);
    }

    /**
     * @notice Function to call token permit method of extended ERC20
     + @param token ERC20 token address
     * @param amount Quantity that is expected to be allowed
     * @param permitData Raw data of the call `permit` of the token
     */
    function _permit(
        address token,
        uint256 amount,
        bytes calldata permitData
    ) internal {
        bytes4 sig = bytes4(permitData[:4]);
        if (sig == _PERMIT_SIGNATURE) {
            (
                address owner,
                address spender,
                uint256 value,
                uint256 deadline,
                uint8 v,
                bytes32 r,
                bytes32 s
            ) = abi.decode(
                    permitData[4:],
                    (
                        address,
                        address,
                        uint256,
                        uint256,
                        uint8,
                        bytes32,
                        bytes32
                    )
                );
            if (owner != msg.sender) {
                revert NotValidOwner();
            }
            if (spender != address(this)) {
                revert NotValidSpender();
            }

            if (value != amount) {
                revert NotValidAmount();
            }

            // we call without checking the result, in case it fails and he doesn't have enough balance
            // the following transferFrom should be fail. This prevents DoS attacks from using a signature
            // before the smartcontract call
            /* solhint-disable avoid-low-level-calls */
            address(token).call(
                abi.encodeWithSelector(
                    _PERMIT_SIGNATURE,
                    owner,
                    spender,
                    value,
                    deadline,
                    v,
                    r,
                    s
                )
            );
        } else {
            if (sig != _PERMIT_SIGNATURE_DAI) {
                revert NotValidSignature();
            }

            (
                address holder,
                address spender,
                uint256 nonce,
                uint256 expiry,
                bool allowed,
                uint8 v,
                bytes32 r,
                bytes32 s
            ) = abi.decode(
                    permitData[4:],
                    (
                        address,
                        address,
                        uint256,
                        uint256,
                        bool,
                        uint8,
                        bytes32,
                        bytes32
                    )
                );

            if (holder != msg.sender) {
                revert NotValidOwner();
            }

            if (spender != address(this)) {
                revert NotValidSpender();
            }

            // we call without checking the result, in case it fails and he doesn't have enough balance
            // the following transferFrom should be fail. This prevents DoS attacks from using a signature
            // before the smartcontract call
            /* solhint-disable avoid-low-level-calls */
            address(token).call(
                abi.encodeWithSelector(
                    _PERMIT_SIGNATURE_DAI,
                    holder,
                    spender,
                    nonce,
                    expiry,
                    allowed,
                    v,
                    r,
                    s
                )
            );
        }
    }

    function _deployWrappedToken(
        bytes32 salt,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) internal returns (IERCXXX newWrappedToken) {
        bytes memory initBytecode = ercxxxBytecode.length == 0 ?
            abi.encodePacked(BASE_INIT_BYTECODE_WRAPPED_TOKEN, abi.encode(name, symbol, decimals))
            : ercxxxBytecode;

        /// @solidity memory-safe-assembly
        assembly {
            newWrappedToken := create2(
                0,
                add(initBytecode, 0x20),
                mload(initBytecode),
                salt
            )
        }
        if (address(newWrappedToken) == address(0))
            revert FailedTokenWrappedDeployment();

        require(core != address(0), "Core is not set");

        IERCXXX(newWrappedToken).initialize(core, name, symbol, decimals);
    }

    // Helpers to safely get the metadata from a token, inspired by https://github.com/traderjoe-xyz/joe-core/blob/main/contracts/MasterChefJoeV3.sol#L55-L95

    /**
     * @notice Provides a safe ERC20.symbol version which returns 'NO_SYMBOL' as fallback string
     * @param token The address of the ERC-20 token contract
     */
    function _safeSymbol(address token) internal view returns (string memory) {
        (bool success, bytes memory data) = address(token).staticcall(
            abi.encodeCall(IERC20MetadataUpgradeable.symbol, ())
        );
        return success ? _returnDataToString(data) : "NO_SYMBOL";
    }

    /**
     * @notice  Provides a safe ERC20.name version which returns 'NO_NAME' as fallback string.
     * @param token The address of the ERC-20 token contract.
     */
    function _safeName(address token) internal view returns (string memory) {
        (bool success, bytes memory data) = address(token).staticcall(
            abi.encodeCall(IERC20MetadataUpgradeable.name, ())
        );
        return success ? _returnDataToString(data) : "NO_NAME";
    }

    /**
     * @notice Provides a safe ERC20.decimals version which returns '18' as fallback value.
     * Note Tokens with (decimals > 255) are not supported
     * @param token The address of the ERC-20 token contract
     */
    function _safeDecimals(address token) internal view returns (uint8) {
        (bool success, bytes memory data) = address(token).staticcall(
            abi.encodeCall(IERC20MetadataUpgradeable.decimals, ())
        );
        return success && data.length == 32 ? abi.decode(data, (uint8)) : 18;
    }

    /**
     * @notice Function to convert returned data to string
     * returns 'NOT_VALID_ENCODING' as fallback value.
     * @param data returned data
     */
    function _returnDataToString(
        bytes memory data
    ) internal pure returns (string memory) {
        if (data.length >= 64) {
            return abi.decode(data, (string));
        } else if (data.length == 32) {
            // Since the strings on bytes32 are encoded left-right, check the first zero in the data
            uint256 nonZeroBytes;
            while (nonZeroBytes < 32 && data[nonZeroBytes] != 0) {
                nonZeroBytes++;
            }

            // If the first one is 0, we do not handle the encoding
            if (nonZeroBytes == 0) {
                return "NOT_VALID_ENCODING";
            }
            // Create a byte array with nonZeroBytes length
            bytes memory bytesArray = new bytes(nonZeroBytes);
            for (uint256 i = 0; i < nonZeroBytes; i++) {
                bytesArray[i] = data[i];
            }
            return string(bytesArray);
        } else {
            return "NOT_VALID_ENCODING";
        }
    }

    /**
     * @notice Returns the encoded token metadata
     * @param token Address of the token
     */

    function getTokenMetadata(
        address token
    ) public view returns (bytes memory) {
        return
            abi.encode(
                _safeName(token),
                _safeSymbol(token),
                _safeDecimals(token)
            );
    }

    /**
     * @notice Returns the precalculated address of a wrapper using the token address
     * Note Updating the metadata of a token is not supported.
     * Since the metadata has relevance in the address deployed, this function will not return a valid
     * wrapped address if the metadata provided is not the original one.
     * @param originNetwork Origin network
     * @param originTokenAddress Origin token address, 0 address is reserved for ether
     * @param token Address of the token to calculate the wrapper address
     */
    function calculateTokenWrapperAddress(
        uint32 originNetwork,
        address originTokenAddress,
        address token
    ) external view returns (address) {
        return
            precalculatedWrapperAddress(
                originNetwork,
                originTokenAddress,
                _safeName(token),
                _safeSymbol(token),
                _safeDecimals(token)
            );
    }

    function setBytecode(bytes memory _bytecode) external {
        ercxxxBytecode = _bytecode;
    }

    function setCore(address _core) external {
        core = _core;
    }

    function deployWETH() external {
        require(address(WETHToken) == address(0), "WETH already deployed");
        WETHToken = _deployWrappedToken(
                0, // salt
                "Wrapped Ether",
                "WETH",
                18
            );
    }
}
