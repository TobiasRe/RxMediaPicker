import Foundation
import MobileCoreServices
import RxSwift
import UIKit
import AVFoundation

public typealias FileInfo = [String: Any]

enum RxMediaPickerAction {
    case photo(observer: AnyObserver<(FileInfo, UIImage, UIImage?)>)
    case video(observer: AnyObserver<URL>, maxDuration: TimeInterval)
    case document(observer: AnyObserver<[URL]>)
}

public enum RxMediaPickerError: Error {
    case generalError
    case canceled
    case videoMaximumDurationExceeded
}

@objc public protocol RxMediaPickerDelegate {
    func present(picker: UIViewController)
    func dismiss(picker: UIViewController)
}

@objc open class RxMediaPicker: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate {
    
    weak var delegate: RxMediaPickerDelegate?
    
    fileprivate var currentAction: RxMediaPickerAction?
    
    open var deviceHasCamera: Bool {
        return UIImagePickerController.isSourceTypeAvailable(.camera)
    }
    
    public init(delegate: RxMediaPickerDelegate) {
        self.delegate = delegate
    }
    
    open func recordVideo(device: UIImagePickerControllerCameraDevice = .rear,
                          quality: UIImagePickerControllerQualityType = .typeMedium,
                          maximumDuration: TimeInterval = 600, editable: Bool = false) -> Observable<URL> {
        return Observable.create { observer in
            self.currentAction = RxMediaPickerAction.video(observer: observer, maxDuration: maximumDuration)
            
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.mediaTypes = [kUTTypeMovie as String]
            picker.videoMaximumDuration = maximumDuration
            picker.videoQuality = quality
            picker.allowsEditing = editable
            picker.delegate = self
            
            if UIImagePickerController.isCameraDeviceAvailable(device) {
                picker.cameraDevice = device
            }
            
            self.presentPicker(picker)
            
            return Disposables.create()
        }
    }
    
    open func selectVideo(source: UIImagePickerControllerSourceType = .photoLibrary,
                          maximumDuration: TimeInterval = 600,
                          editable: Bool = false) -> Observable<URL> {
        return Observable.create { [unowned self] observer in
            self.currentAction = RxMediaPickerAction.video(observer: observer, maxDuration: maximumDuration)
            
            let picker = UIImagePickerController()
            picker.sourceType = source
            picker.mediaTypes = [kUTTypeMovie as String]
            picker.allowsEditing = editable
            picker.delegate = self
            picker.videoMaximumDuration = maximumDuration
            
            self.presentPicker(picker)
            
            return Disposables.create()
        }
    }
    
    open func takePhoto(device: UIImagePickerControllerCameraDevice = .rear,
                        flashMode: UIImagePickerControllerCameraFlashMode = .auto,
                        editable: Bool = false) -> Observable<(FileInfo, UIImage, UIImage?)> {
        return Observable.create { [unowned self] observer in
            self.currentAction = RxMediaPickerAction.photo(observer: observer)
            
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.allowsEditing = editable
            picker.delegate = self
            
            if UIImagePickerController.isCameraDeviceAvailable(device) {
                picker.cameraDevice = device
            }
            
            if UIImagePickerController.isFlashAvailable(for: picker.cameraDevice) {
                picker.cameraFlashMode = flashMode
            }
            
            self.presentPicker(picker)
            
            return Disposables.create()
        }
    }
    
    open func selectImage(source: UIImagePickerControllerSourceType = .photoLibrary,
                          editable: Bool = false) -> Observable<(FileInfo, UIImage, UIImage?)> {
        return Observable.create { [unowned self] observer in
            self.currentAction = RxMediaPickerAction.photo(observer: observer)
            
            let picker = UIImagePickerController()
            picker.sourceType = source
            picker.allowsEditing = editable
            picker.delegate = self
            
            self.presentPicker(picker)
            
            return Disposables.create()
        }
    }
    
    open func selectDocuments(documentTypes: [String], in mode: UIDocumentPickerMode) -> Observable<([URL])> {
        return Observable.create { [unowned self] observer in
            self.currentAction = RxMediaPickerAction.document(observer: observer)
            
            let picker = UIDocumentPickerViewController(documentTypes: documentTypes, in: mode)
            
            self.presentPicker(picker)
            
            return Disposables.create()
        }
    }
    
    func processDocuments(documents: [URL],
                      observer: AnyObserver<[URL]>) {
        observer.on(.next(documents))
        observer.on(.completed)
    }
    
    func processPhoto(info: FileInfo,
                      observer: AnyObserver<(FileInfo, UIImage, UIImage?)>) {
        guard let image = info[UIImagePickerControllerOriginalImage] as? UIImage else {
            observer.on(.error(RxMediaPickerError.generalError))
            return
        }

        let editedImage = info[UIImagePickerControllerEditedImage] as? UIImage

        observer.on(.next((info, image, editedImage)))
        observer.on(.completed)
    }
    
    func processVideo(info: FileInfo,
                      observer: AnyObserver<URL>,
                      maxDuration: TimeInterval,
                      picker: UIImagePickerController) {
        guard let videoURL = info[UIImagePickerControllerMediaURL] as? URL else {
            observer.on(.error(RxMediaPickerError.generalError))
            dismissPicker(picker)
            return
        }

        guard let editedStart = info["_UIImagePickerControllerVideoEditingStart"] as? NSNumber,
              let editedEnd = info["_UIImagePickerControllerVideoEditingEnd"] as? NSNumber else {
            processVideo(url: videoURL, observer: observer, maxDuration: maxDuration, picker: picker)
            return
        }

        let start = Int64(editedStart.doubleValue * 1000)
        let end = Int64(editedEnd.doubleValue * 1000)
        let cachesDirectory = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first!
        let editedVideoURL = URL(fileURLWithPath: cachesDirectory).appendingPathComponent("\(UUID().uuidString).mov", isDirectory: false)
        let asset = AVURLAsset(url: videoURL)
        
        if let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) {
            exportSession.outputURL = editedVideoURL
            exportSession.outputFileType = AVFileType.mov
            exportSession.timeRange = CMTimeRange(start: CMTime(value: start, timescale: 1000), duration: CMTime(value: end - start, timescale: 1000))
            
            exportSession.exportAsynchronously(completionHandler: {
                switch exportSession.status {
                case .completed:
                    self.processVideo(url: editedVideoURL, observer: observer, maxDuration: maxDuration, picker: picker)
                case .failed: fallthrough
                case .cancelled:
                    observer.on(.error(RxMediaPickerError.generalError))
                    self.dismissPicker(picker)
                default: break
                }
            })
        }
    }
    
    fileprivate func processVideo(url: URL,
                                  observer: AnyObserver<URL>,
                                  maxDuration: TimeInterval,
                                  picker: UIImagePickerController) {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        
        if duration > maxDuration {
            observer.on(.error(RxMediaPickerError.videoMaximumDurationExceeded))
        } else {
            observer.on(.next(url))
            observer.on(.completed)
        }
        
        dismissPicker(picker)
    }

    fileprivate func presentPicker(_ picker: UIViewController) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.present(picker: picker)
        }
    }
    
    fileprivate func dismissPicker(_ picker: UIViewController) {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.dismiss(picker: picker)
        }
    }
    
    // MARK: UIImagePickerControllerDelegate
    open func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: FileInfo) {
        if let action = currentAction {
            switch action {
            case .photo(let observer):
                processPhoto(info: info, observer: observer)
                dismissPicker(picker)
            case .video(let observer, let maxDuration):
                processVideo(info: info, observer: observer, maxDuration: maxDuration, picker: picker)
            case .document(_):
                //No Document selected
                dismissPicker(picker)
            }
        }
    }
    
    open func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        dismissPicker(picker)
        
        if let action = currentAction {
            switch action {
            case .photo(let observer):      observer.on(.error(RxMediaPickerError.canceled))
            case .video(let observer, _):   observer.on(.error(RxMediaPickerError.canceled))
            case .document(let observer):   observer.on(.error(RxMediaPickerError.canceled))
            }
        }
    }
    
    // MARK: UIDocumentPickerControllerDelegate
    open func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        documentPicker(controller, didPickDocumentsAt: [url])
    }
    
    open func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let action = currentAction {
            switch action {
            case .photo(_):
                //No Photo selected
                break
            case .video(_):
                //No Video selected
                break
            case .document(let observer):
                processDocuments(documents: urls, observer: observer)
            }
            dismissPicker(controller)
        }
    }
    
    open func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        dismissPicker(controller)
        
        if let action = currentAction {
            switch action {
            case .photo(let observer):      observer.on(.error(RxMediaPickerError.canceled))
            case .video(let observer, _):   observer.on(.error(RxMediaPickerError.canceled))
            case .document(let observer):   observer.on(.error(RxMediaPickerError.canceled))
            }
        }
    }
}
