import Foundation
import ORSSerial

open class ThreadSafeSerialPortController: NSObject, SerialPortController, SerialPacketOperationDelegate {
    /**
     */
    public required init(matching portProfile: ORSSerialPortManager.PortProfile) throws {
        self.reader = try ORSSerialPortManager.port(matching: portProfile)
        super.init()
    }
    
    ///
    let reader: ORSSerialPort
    
    ///
    private let isOpenCondition = NSCondition()
    
    ///
    private var currentDelegate: ORSSerialPortDelegate? = nil // Prevents 'deinit'
    private var        delegate: ORSSerialPortDelegate? {
        get { return reader.delegate     }
        set {
            currentDelegate = newValue
            reader.delegate = newValue
        }
    }
    
    /**
     */
    open class var portProfile: ORSSerialPortManager.PortProfile {
        return .prefix("/dev/cu.usbserial-14")
    }
    
    open func open() {
        self.reader.open()
    }

    /**
     */
    public final func openReader(delegate: ORSSerialPortDelegate?) {
        self.isOpenCondition.whileLocked {
            while self.currentDelegate != nil {
                self.isOpenCondition.wait()
            }
            
            // print("Continuing...")
            self.delegate = delegate
            //------------------------------------------------------------------
            DispatchQueue.main.sync {
                if self.reader.isOpen == false {
                    self.open()
                }
            }
        }
    }
    
    /**
     */
    @discardableResult
    public final func send(_ data: Data?) -> Bool {
        guard let data = data else {
            return false
        }
        return self.reader.send(data)
    }
    
    open func version<Version>(_ callback: @escaping ((Version?) -> ())) {
        callback(nil)
    }
}

extension ThreadSafeSerialPortController {
    ///
    public var isOpen: Bool {
        return self.reader.isOpen
    }
    
    /**
     */
    @discardableResult
    public final func close() -> Bool {
        return self.reader.close()
    }
}

extension ThreadSafeSerialPortController {
    /**
     */
    @objc public func packetOperation(_ operation: Operation, didComplete intent: Any?) {
        self.isOpenCondition.whileLocked {
            self.delegate = nil
            self.isOpenCondition.signal()
        }
    }
}

extension SerialPortController where Self: ThreadSafeSerialPortController {
    /**
    Peforms an asychronous `block` operation while the serial port is open.
    
    - parameters:
    - block: The block executed while the serial port is opened.
    - callback: An optional value returned by `block`.
    
    - note:
    By the time `block` completes execution, the serial port will have
    been closed.
    */
    func whileOpened(perform block: @escaping () -> (), _ callback: @escaping (Data?) -> ()) {
        var operation: OpenPortOperation<Self>! = nil {
            didSet {
                operation.start()
            }
        }
        operation = OpenPortOperation<Self>(controller: self) { _ in
            block()
            callback(operation.buffer)
        }
    }
}