import UIKit
import SnapKit

class BookGroupViewController: UIViewController {

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.delegate = self
        tv.dataSource = self
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        return tv
    }()
    
    private var groups: [BookGroupResponse] = []
    private var isLoading = false

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadGroups()
    }
    
    private func setupUI() {
        title = "分组管理"
        view.backgroundColor = .systemBackground
        
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(addGroup)
        )
        
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }
    
    private func loadGroups() {
        guard ReaderServerAPI.shared.isLoggedIn else {
            showLoginAlert()
            return
        }
        
        isLoading = true
        
        Task {
            do {
                let loadedGroups = try await ReaderServerAPI.shared.getBookGroups()
                await MainActor.run {
                    self.groups = loadedGroups
                    self.tableView.reloadData()
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.showError(error.localizedDescription)
                    self.isLoading = false
                }
            }
        }
    }
    
    @objc private func addGroup() {
        let alert = UIAlertController(title: "新建分组", message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "分组名称"
        }
        
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
            guard let name = alert.textFields?.first?.text, !name.isEmpty else { return }
            self?.createGroup(name: name)
        })
        
        present(alert, animated: true)
    }
    
    private func createGroup(name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            showError("分组名称不能为空")
            return
        }

        if BookParseManager.shared.isServerMode {
            showError("服务器模式暂不支持创建分组，请前往服务端管理")
            return
        }

        if groups.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            showError("分组名称已存在")
            return
        }

        BookGroupManager.shared.addGroup(name: trimmedName)
        groups = BookGroupManager.shared.getAllGroups().map {
            BookGroupResponse(id: $0.groupId, name: $0.groupName, bookCount: $0.bookCount)
        }
        tableView.reloadData()
    }
    
    private func showLoginAlert() {
        let alert = UIAlertController(title: "提示", message: "请先连接服务器", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }
    
    private func showError(_ message: String) {
        let alert = UIAlertController(title: "错误", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
}

extension BookGroupViewController: UITableViewDelegate, UITableViewDataSource {
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return groups.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        let group = groups[indexPath.row]
        
        var config = cell.defaultContentConfiguration()
        config.text = group.name
        config.secondaryText = "\(group.bookCount)本书"
        config.image = UIImage(systemName: "folder")
        
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }
    
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let group = groups[indexPath.row]
        
        if group.id <= 0 {
            return nil
        }
        
        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            self?.deleteGroup(group)
            completion(true)
        }
        deleteAction.image = UIImage(systemName: "trash")
        
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }
    
    private func deleteGroup(_ group: BookGroupResponse) {
        if BookParseManager.shared.isServerMode {
            showError("服务器模式暂不支持删除分组，请前往服务端管理")
            return
        }

        BookGroupManager.shared.deleteGroup(group.id)
        groups.removeAll { $0.id == group.id }
        tableView.reloadData()
    }
}
