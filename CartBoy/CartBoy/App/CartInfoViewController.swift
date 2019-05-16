import AppKit
import Gibby
import CartKit

class CartInfoViewController: ContextViewController {
    @IBOutlet weak var saveActionContainerView: NSView!
    @IBOutlet weak var gridView: NSGridView!
    @IBOutlet weak var saveDataProgressBar: NSProgressIndicator!
    @IBOutlet weak var saveActionsStackView: NSStackView!
    @IBOutlet weak var saveNotSupportedStackView: NSStackView!

    private var clearGridViewDisplay: Result<(), Error> {
        return Result {
            DispatchQueue.main.sync {
                guard let gridView = self.gridView else {
                    return
                }
                for row in 0..<gridView.numberOfRows {
                    if let textField = gridView.column(at: 1).cell(at: row).contentView as? NSTextField {
                        textField.stringValue = ""
                    }
                }
            }
        }
    }
    
    private func updateClassicSaveUI<Header: Gibby.Header>(with header: Header) -> Result<Header, Error> where Header.Platform == GameboyClassic {
        return Result {
            DispatchQueue.main.sync {
                if header.configuration.hardware.contains(.ram) {
                    self.saveNotSupportedStackView?.isHidden = true
                    self.saveActionsStackView?.isHidden = false
                } else {
                    self.saveNotSupportedStackView?.isHidden = false
                    self.saveActionsStackView?.isHidden = true
                    self.saveDataProgressBar?.isHidden = true
                }
                return header
            }
        }
    }
    
    private func updateClassicHeaderUI<Header: Gibby.Header>(with header: Header) -> Result<Header, Error> where Header.Platform == GameboyClassic {
        return Result {
            DispatchQueue.main.sync {
                func set(string value: String, rowIndex: Int) {
                    DispatchQueue.main.async {
                        if let textField = self.gridView.cell(atColumnIndex: 1, rowIndex: rowIndex).contentView as? NSTextField {
                            textField.stringValue = value
                        }
                    }
                }
                
                let byteCountFormatter = ByteCountFormatter()
                
                byteCountFormatter.allowedUnits = .useBytes
                let kilobyteString = byteCountFormatter.string(fromByteCount: Int64(header.romSize))
                
                byteCountFormatter.allowedUnits = .useMB
                let megabyteString = byteCountFormatter.string(fromByteCount: Int64(header.romSize))
                
                set(string: header.title, rowIndex: 0)
                set(string: "\(header.configuration)", rowIndex: 1)
                set(string: "\(kilobyteString) (\(megabyteString))", rowIndex: 2)
                set(string: "\(header.region)".uppercased(), rowIndex: 3)
                set(string: "\(header.superGameboySupported)".uppercased(), rowIndex: 4)
                
                return header
            }
        }
    }
    
    override func awakeFromNib() {
        super.awakeFromNib()
        
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.cartInfoController = self
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.context.perform {
            try! self.clearGridViewDisplay.get()
            try! Result { Data(count: GameboyClassic.headerRange.count) }
                .map { GameboyClassic.Header(bytes: $0) }
                .map { self.updateClassicSaveUI(with: $0) }
                .map { _ in () }
                .get()
        }
    }
    
    @IBAction func readHeader(_ sender: Any?) {
        self.context.perform {
            let header = self.clearGridViewDisplay
                .flatMap { Result { try insideGadgetsController<GameboyClassic>() } }
                .flatMap { controller in Result { try await { controller.scanHeader($0) } } }
                .flatMap { header in self.updateClassicHeaderUI(with: header) }
                .flatMap { header in self.updateClassicSaveUI(with: header) }
            
            switch header {
            case .success: (/* no-op */)
            case .failure(let error): self.context.display(error: error, in: self)
            }
        }
    }
    
    @IBAction func readSaveData(_ sender: Any?) {
        self.context.perform {
            let result = Result<(Data, GameboyClassic.Header), Error> {
                DispatchQueue.main.sync { self.saveDataProgressBar.isHidden = false }
                let controller = try insideGadgetsController<GameboyClassic>()
                let header     = try await { controller.scanHeader($0) }
                let saveData   = try await { controller.backupSave(progress: {
                    self.context.update(progressBar: self.saveDataProgressBar, with: $0)
                }, $0) }
                return (saveData, header)
            }
            
            switch result {
            case .success(let saveData, let header):
                DispatchQueue.main.sync {
                    let savePanel = NSSavePanel()
                    savePanel.nameFieldStringValue = "\(header.title).sav"
                    self.context.display(savePanel: savePanel) { response in
                        self.saveDataProgressBar.doubleValue = 0
                        self.saveDataProgressBar.isHidden = true
                        
                        guard let url = savePanel.url, case .OK = response else {
                            return
                        }
                        do {
                            try saveData.write(to: url)
                        } catch {
                            self.context.display(error: error, in: self)
                        }
                    }
                }
            case .failure(let error): self.context.display(error: error, in: self)
            }
        }
    }
    
    @IBAction func writeSaveData(_ sender: Any?) {
        guard let window = NSApp.mainWindow else {
            return
        }
        let openPanel = NSOpenPanel()
        openPanel.beginSheetModal(for: window) {
            guard case .OK = $0, let url = openPanel.url, let data = try? Data(contentsOf: url) else {
                return
            }
            
            self.saveDataProgressBar.isHidden = false

            self.context.perform {
                let result = Result<(), Error> {
                    let controller = try insideGadgetsController<GameboyClassic>()
                    let _/*header*/= try await { controller.scanHeader($0) }
                    /*
                    let _ /*erase*/= try await { controller.deleteSave(progress: {
                        self.context.update(progressBar: self.saveDataProgressBar, with: $0)
                    }, $0) }
                     */
                    let restoreData: Void = try await { controller.restoreSave(data: data, progress: {
                        self.context.update(progressBar: self.saveDataProgressBar, with: $0)
                    }, $0) }
                    return restoreData
                }
                
                DispatchQueue.main.sync {
                    self.saveDataProgressBar.isHidden = true
                    self.saveDataProgressBar.doubleValue = 0.0
                }
                
                switch result {
                case .success: ()
                case .failure(let error): self.context.display(error: error, in: self)
                }
            }
        }
    }
    
    @IBAction func eraseSaveData(_ sender: Any?) {
        guard let window = NSApp.mainWindow else {
            return
        }
        
        let alert = NSAlert()
        alert.messageText = "Erasing Save Data"
        alert.informativeText = "If save data is erased, any game progress will be reset. Consider backing up save data first, if necessary."
        alert.addButton(withTitle: "Erase")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        
        alert.beginSheetModal(for: window) {
            guard $0 == .alertFirstButtonReturn else {
                return
            }
            
            self.saveDataProgressBar.isHidden = false
            
            self.context.perform {
                let result = Result<(), Error> {
                    let controller = try insideGadgetsController<GameboyClassic>()
                    let _/*header*/= try await { controller.scanHeader($0) }
                    let eraseData: Void = try await { controller.deleteSave(progress: {
                        self.context.update(progressBar: self.saveDataProgressBar, with: $0)
                    }, $0) }
                    return eraseData
                }
                
                DispatchQueue.main.sync {
                    self.saveDataProgressBar.isHidden = true
                    self.saveDataProgressBar.doubleValue = 0.0
                }
                
                switch result {
                case .success(): ()
                case .failure(let error): self.context.display(error: error, in: self)
                }
            }
        }
    }
}
