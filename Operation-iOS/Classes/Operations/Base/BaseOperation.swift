import Foundation

/// Type defines a closure that can be provided to configure an operation.
public typealias OperationConfigBlock = () -> Void

/**
 *  Enum is designed to define most common errors related
 *  to operations.
 */
public enum BaseOperationError: Error {
    /// Parameter operation has been unexpectedly cancelled.
    case parentOperationCancelled

    /// Dependency operation provided unexpected result.
    case unexpectedDependentResult
}

/**
 *  Class is designed to provide base implementation
 *  of generic async operation.
 *
 *  Operation contains configuration closure that is executed
 *  when operation starts to setup internal parameters based on dependencies.
 *  Moreover it maintains Swift result which is:
 *  - remains ```nil``` if operation is cancelled;
 *  - is initialized with generic value in case of success;
 *  - is initialized with error in case of failure;
 */

open class BaseOperation<ResultType>: Operation {
    override open var isAsynchronous: Bool {
        return true
    }
    
    private let mutex = NSLock()
    
    private var _isExecuting: Bool = false
    override public private(set) var isExecuting: Bool {
        get {
            mutex.lock()
            
            defer {
                mutex.unlock()
            }
            
            return _isExecuting
        }
        
        set {
            willChangeValue(forKey: "isExecuting")
            
            mutex.lock()
            
            _isExecuting = newValue
            
            mutex.unlock()
            
            didChangeValue(forKey: "isExecuting")
        }
    }
    
    private var _isFinished: Bool = false
    override public private(set) var isFinished: Bool {
        get {
            mutex.lock()
            
            defer {
                mutex.unlock()
            }
            
            return _isFinished
        }
        set {
            willChangeValue(forKey: "isFinished")
            
            mutex.lock()
            
            _isFinished = newValue
            
            mutex.unlock()
            
            didChangeValue(forKey: "isFinished")
        }
    }
    
    private var _result: Result<ResultType, Error>?
    
    /**
     *  Result of the operation which is:
     *  - remains ```nil``` if operation is cancelled;
     *  - is initialized with generic value in case of success;
     *  - is initialized with error in case of failure;
     */
    open var result: Result<ResultType, Error>? {
        get {
            mutex.lock()
            
            defer {
                mutex.unlock()
            }
            
            return _result
        }
        
        set {
            mutex.lock()
            
            _result = newValue
            
            mutex.unlock()
        }
    }
    
    private var _configurationBlock: OperationConfigBlock?
    
    /**
     *  Configuration closure to execute when operation starts.
     *
     *  Closure is automatically set to ```nil``` after execution.
     */
    open var configurationBlock: OperationConfigBlock? {
        get {
            mutex.lock()
            
            defer {
                mutex.unlock()
            }
            
            return _configurationBlock
        }
        
        set {
            mutex.lock()
            
            _configurationBlock = newValue
            
            mutex.unlock()
        }
    }

    open override func start() {
        configurationBlock?()
        configurationBlock = nil
        
        if isCancelled {
            finish()
            return
        }

        if result != nil {
            finish()
            return
        }
        
        isFinished = false
        isExecuting = true
        main()
    }

    open override func main() {
        do {
            try performAsync { operationResult in
                self.result = operationResult
                self.finish()
            }

        } catch {
            result = .failure(error)
            finish()
        }
    }
    
    open override func cancel() {
        configurationBlock = nil
        
        super.cancel()
    }

    open func performAsync(_ callback: @escaping (Result<ResultType, Error>) -> Void) throws {
        fatalError("Must be overriden by subsclass")
    }
    
    func finish() {
        isExecuting = false
        isFinished = true
    }
}
