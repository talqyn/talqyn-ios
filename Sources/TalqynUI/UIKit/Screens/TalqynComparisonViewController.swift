#if os(iOS)
import TalqynConsultantCore
import TalqynSDK
import UIKit

/// A comparison table: product headers across the top, characteristics
/// down the side, values in between. The characteristic column stays put
/// while the values scroll sideways, and "only differences" hides the rows
/// where every product says the same thing.
public final class TalqynComparisonViewController: UIViewController {
    private struct Column {
        let product: TalqynProduct?
        let title: String
    }

    private struct Model {
        let columns: [Column]
        let rows: [TalqynComparisonRow]

        init(columns: [Column], rows: [TalqynComparisonTable.Row]) {
            self.columns = columns
            self.rows = rows.map { TalqynComparisonRow(row: $0, isPrice: Self.isPriceRow($0, columns: columns)) }
        }

        private init(columns: [Column], comparisonRows: [TalqynComparisonRow]) {
            self.columns = columns
            rows = comparisonRows
        }

        var hasDifferences: Bool { rows.contains { differs($0.row) } }

        func keepingOnlyDifferences() -> Model {
            Model(columns: columns, comparisonRows: rows.filter { differs($0.row) })
        }

        private func differs(_ row: TalqynComparisonTable.Row) -> Bool {
            let values = (0..<columns.count).map { index in index < row.values.count ? (row.values[index] ?? "") : "" }
            return Set(values).count > 1
        }

        /// Whether a row holds the products' prices — to write them as
        /// prices rather than as the bare numbers the table carries.
        ///
        /// Recognized by its values, not its label: the label is the server's
        /// wording in one language, and a row whose every number is the price
        /// of its column's product is a price row in any language. A column
        /// whose product or price is unknown neither confirms nor refutes it.
        static func isPriceRow(_ row: TalqynComparisonTable.Row, columns: [Column]) -> Bool {
            var matched = 0
            for (index, column) in columns.enumerated() {
                guard index < row.values.count, let raw = row.values[index] else { continue }
                guard let value = Double(raw.trimmingCharacters(in: .whitespaces)) else { return false }
                guard let price = column.product?.price else { continue }
                guard abs(value - price) < 0.01 else { return false }
                matched += 1
            }
            return matched > 0
        }
    }

    private let theme: TalqynTheme
    private let strings: TalqynUIStrings
    private let price: TalqynPriceFormatter
    private let loader: TalqynImageLoading
    private let model: Model
    private let onOpenProduct: (TalqynProduct) -> Void

    private let titleLabel = UILabel()
    private let closeButton = TalqynHitAreaButton(type: .system)
    private let differencesButton = TalqynHitAreaButton(type: .system)
    private let emptyLabel = UILabel()
    private let productsScrollView = UIScrollView()
    private let productsStack = UIStackView()
    private let bodyScrollView = UIScrollView()
    private let tableView: TalqynComparisonTableView
    private var showsOnlyDifferences = false
    private var laidOutWidth: CGFloat = 0
    private var columnWidth = TalqynComparisonTableView.minColumnWidth

    /// Creates the screen.
    ///
    /// - Parameters:
    ///   - table: The table the consultant proposed.
    ///   - products: The turn's products by Talqyn id, for the headers.
    ///   - theme: Colors and fonts.
    ///   - strings: Copy. Defaults to Russian; the consultant screen passes
    ///     its own.
    ///   - priceFormatter: How prices are written.
    ///   - imageLoader: Loads product images. Defaults to
    ///     ``TalqynURLImageLoader/shared``, whose cache every screen shares.
    ///   - onOpenProduct: A header was tapped. The screen dismisses itself first.
    public init(
        table: TalqynComparisonTable,
        products: [Int: TalqynProduct],
        theme: TalqynTheme = .default,
        strings: TalqynUIStrings = .en,
        priceFormatter: TalqynPriceFormatter = .tenge,
        imageLoader: TalqynImageLoading = TalqynURLImageLoader.shared,
        onOpenProduct: @escaping (TalqynProduct) -> Void
    ) {
        self.theme = theme
        self.strings = strings
        price = priceFormatter
        loader = imageLoader
        self.onOpenProduct = onOpenProduct
        let columns = table.titles.enumerated().map { index, title -> Column in
            let product = index < table.talqynIDs.count ? products[table.talqynIDs[index]] : nil
            return Column(product: product, title: product?.title ?? title)
        }
        model = Model(columns: columns, rows: table.rows)
        tableView = TalqynComparisonTableView(theme: theme, price: priceFormatter)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        productsScrollView.delegate = self
        tableView.valuesScrollView.delegate = self
    }

    /// The columns share the width, so they are laid out again whenever it
    /// changes: a rotation, an iPad window resized.
    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        guard width > 0, width != laidOutWidth else { return }
        laidOutWidth = width
        columnWidth = TalqynComparisonTableView.columnWidth(forColumns: model.columns.count, availableWidth: width)
        productsStack.talqynRemoveAllArranged()
        for column in model.columns {
            productsStack.addArrangedSubview(makeProductCard(column, width: columnWidth))
        }
        reloadRows()
    }

    private func reloadRows() {
        let shown = showsOnlyDifferences ? model.keepingOnlyDifferences() : model
        tableView.configure(columns: shown.columns.count, rows: shown.rows, columnWidth: columnWidth)
        tableView.isHidden = shown.rows.isEmpty
        emptyLabel.isHidden = !shown.rows.isEmpty
        differencesButton.setTitleColor(showsOnlyDifferences ? theme.colors.accent : theme.colors.textSecondary, for: .normal)
        differencesButton.accessibilityTraits = showsOnlyDifferences ? [.button, .selected] : .button
    }

    @objc private func differencesTapped() {
        showsOnlyDifferences.toggle()
        bodyScrollView.setContentOffset(.zero, animated: false)
        reloadRows()
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    private func makeProductCard(_ column: Column, width: CGFloat) -> UIView {
        let imageView = TalqynRemoteImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = theme.colors.surfaceSecondary
        imageView.talqynRound(theme.metrics.cardRadius)
        imageView.talqynSize(64)
        imageView.setPlaceholder(theme.icons.imagePlaceholder, tint: theme.colors.textTertiary)
        imageView.setImage(url: column.product?.imageURL, loader: loader)

        let titleLabel = UILabel()
        titleLabel.font = theme.fonts.captionBold
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = theme.colors.textPrimary
        titleLabel.numberOfLines = 4
        titleLabel.text = column.title

        let stack = UIStackView.talqynVertical([imageView, titleLabel], spacing: 8)
        stack.alignment = .leading

        let card = TalqynTappableView()
        card.talqynPin(stack, insets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: width).isActive = true
        card.isAccessibilityElement = true
        card.accessibilityLabel = column.title
        if let product = column.product {
            card.accessibilityTraits = .button
            card.onTap = { [weak self] in
                self?.dismiss(animated: true) { self?.onOpenProduct(product) }
            }
        } else {
            card.isUserInteractionEnabled = false
            card.accessibilityTraits = .staticText
        }
        return card
    }

    private func configureUI() {
        overrideUserInterfaceStyle = theme.appearance.interfaceStyle
        view.backgroundColor = theme.colors.surface

        titleLabel.font = theme.fonts.headline
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = theme.colors.textPrimary
        titleLabel.textAlignment = .center
        titleLabel.text = strings.comparisonTitle

        closeButton.setImage(theme.icons.close?.talqynSized(16, .semibold), for: .normal)
        closeButton.tintColor = theme.colors.textPrimary
        closeButton.accessibilityLabel = strings.close
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        differencesButton.titleLabel?.font = theme.fonts.label
        differencesButton.titleLabel?.adjustsFontForContentSizeCategory = true
        differencesButton.contentHorizontalAlignment = .leading
        differencesButton.setTitle(strings.comparisonOnlyDifferences, for: .normal)
        differencesButton.addTarget(self, action: #selector(differencesTapped), for: .touchUpInside)
        differencesButton.isHidden = !model.hasDifferences

        emptyLabel.font = theme.fonts.callout
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = theme.colors.textSecondary
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.text = strings.comparisonNoDifferences
        emptyLabel.isHidden = true

        productsScrollView.showsHorizontalScrollIndicator = false
        productsStack.axis = .horizontal
        productsStack.alignment = .fill
        bodyScrollView.alwaysBounceVertical = true

        let header = UIView()
        let navDivider = TalqynDividerView(theme: theme)
        let productsDivider = TalqynDividerView(theme: theme)
        [header, navDivider, productsScrollView, productsDivider, bodyScrollView, emptyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        [titleLabel, closeButton, differencesButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview($0)
        }
        productsScrollView.addSubview(productsStack)
        bodyScrollView.addSubview(tableView)
        productsStack.translatesAutoresizingMaskIntoConstraints = false
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let margin = theme.metrics.horizontalMargin
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 56),
            titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            differencesButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: margin),
            differencesButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            differencesButton.trailingAnchor.constraint(lessThanOrEqualTo: titleLabel.leadingAnchor, constant: -8),
            navDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
            navDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            productsScrollView.topAnchor.constraint(equalTo: navDivider.bottomAnchor),
            productsScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: TalqynComparisonTableView.labelColumnWidth),
            productsScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            productsStack.topAnchor.constraint(equalTo: productsScrollView.contentLayoutGuide.topAnchor),
            productsStack.bottomAnchor.constraint(equalTo: productsScrollView.contentLayoutGuide.bottomAnchor),
            productsStack.leadingAnchor.constraint(equalTo: productsScrollView.contentLayoutGuide.leadingAnchor),
            productsStack.trailingAnchor.constraint(equalTo: productsScrollView.contentLayoutGuide.trailingAnchor),
            productsStack.heightAnchor.constraint(equalTo: productsScrollView.frameLayoutGuide.heightAnchor),
            productsDivider.topAnchor.constraint(equalTo: productsScrollView.bottomAnchor),
            productsDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            productsDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bodyScrollView.topAnchor.constraint(equalTo: productsDivider.bottomAnchor),
            bodyScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bodyScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bodyScrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            tableView.topAnchor.constraint(equalTo: bodyScrollView.contentLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: bodyScrollView.contentLayoutGuide.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: bodyScrollView.contentLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: bodyScrollView.contentLayoutGuide.trailingAnchor),
            tableView.widthAnchor.constraint(equalTo: bodyScrollView.frameLayoutGuide.widthAnchor),
            emptyLabel.topAnchor.constraint(equalTo: productsDivider.bottomAnchor, constant: 40),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin * 2),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin * 2),
        ])
    }
}

extension TalqynComparisonViewController: UIScrollViewDelegate {
    /// The product headers and the value columns scroll as one.
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let mirrored: UIScrollView
        if scrollView === productsScrollView {
            mirrored = tableView.valuesScrollView
        } else if scrollView === tableView.valuesScrollView {
            mirrored = productsScrollView
        } else {
            return
        }
        guard abs(mirrored.contentOffset.x - scrollView.contentOffset.x) > 0.5 else { return }
        mirrored.contentOffset.x = scrollView.contentOffset.x
    }
}

/// A row of the comparison, with what it is known to hold.
struct TalqynComparisonRow {
    let row: TalqynComparisonTable.Row
    /// Whether the values are the products' prices.
    let isPrice: Bool
}

/// The body of the comparison: a pinned label column and scrolling value
/// columns, rows sized to their tallest cell.
final class TalqynComparisonTableView: UIView {
    static let labelColumnWidth: CGFloat = 116
    static let minColumnWidth: CGFloat = 130

    static func columnWidth(forColumns count: Int, availableWidth: CGFloat) -> CGFloat {
        let available = availableWidth - labelColumnWidth
        guard count > 0, available > 0 else { return minColumnWidth }
        return max(minColumnWidth, floor(available / CGFloat(count)))
    }

    let valuesScrollView = UIScrollView()

    private let theme: TalqynTheme
    private let price: TalqynPriceFormatter
    private let minRowHeight: CGFloat = 40
    private let cellVerticalInset: CGFloat = 10
    private let labelInsets: UIEdgeInsets
    private let valueInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    private let labelColumn = UIStackView.talqynVertical(spacing: 0)
    private let valuesStack = UIStackView()
    private var columnWidth = TalqynComparisonTableView.minColumnWidth

    init(theme: TalqynTheme, price: TalqynPriceFormatter) {
        self.theme = theme
        self.price = price
        labelInsets = UIEdgeInsets(top: 0, left: theme.metrics.horizontalMargin, bottom: 0, right: 8)
        super.init(frame: .zero)
        configureUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(columns: Int, rows: [TalqynComparisonRow], columnWidth: CGFloat) {
        self.columnWidth = columnWidth
        labelColumn.talqynRemoveAllArranged()
        valuesStack.talqynRemoveAllArranged()
        guard columns >= 2, !rows.isEmpty else { return }

        let rowHeights = measureRowHeights(rows, columns: columns)
        for (index, row) in rows.enumerated() {
            labelColumn.addArrangedSubview(makeCell(
                text: capitalized(row.row.label), font: theme.fonts.captionBold, color: theme.colors.textSecondary,
                insets: labelInsets, height: rowHeights[index], background: background(forRow: index)
            ))
        }
        for columnIndex in 0..<columns {
            let column = UIStackView.talqynVertical(spacing: 0)
            for (rowIndex, row) in rows.enumerated() {
                column.addArrangedSubview(makeCell(
                    text: cellText(row, column: columnIndex),
                    font: row.isPrice ? theme.fonts.captionBold : theme.fonts.caption,
                    color: theme.colors.textPrimary,
                    insets: valueInsets, height: rowHeights[rowIndex], background: background(forRow: rowIndex)
                ))
            }
            column.translatesAutoresizingMaskIntoConstraints = false
            column.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
            valuesStack.addArrangedSubview(column)
        }
    }

    private func measureRowHeights(_ rows: [TalqynComparisonRow], columns: Int) -> [CGFloat] {
        rows.map { row in
            var height = textHeight(
                capitalized(row.row.label), font: theme.fonts.captionBold,
                width: Self.labelColumnWidth - labelInsets.left - labelInsets.right
            )
            for columnIndex in 0..<columns {
                height = max(height, textHeight(
                    cellText(row, column: columnIndex),
                    font: row.isPrice ? theme.fonts.captionBold : theme.fonts.caption,
                    width: columnWidth - valueInsets.left - valueInsets.right
                ))
            }
            return max(minRowHeight, ceil(height) + cellVerticalInset * 2)
        }
    }

    private func textHeight(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height
    }

    private func background(forRow index: Int) -> UIColor {
        index.isMultiple(of: 2) ? theme.colors.surface : theme.colors.surfaceSecondary
    }

    private func makeCell(text: String, font: UIFont, color: UIColor, insets: UIEdgeInsets, height: CGFloat, background: UIColor) -> UIView {
        let label = UILabel()
        label.font = font
        label.textColor = color
        label.numberOfLines = 0
        label.text = text
        let container = UIView()
        container.backgroundColor = background
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            container.trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: insets.right),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.talqynHeight(height)
        return container
    }

    private func cellText(_ row: TalqynComparisonRow, column: Int) -> String {
        let value = column < row.row.values.count ? row.row.values[column] : nil
        guard let value, !value.isEmpty else { return "—" }
        guard row.isPrice, let number = Double(value.trimmingCharacters(in: .whitespaces)) else { return value }
        return price.format(number)
    }

    private func capitalized(_ label: String) -> String {
        guard let first = label.first else { return label }
        return first.uppercased() + label.dropFirst()
    }

    private func configureUI() {
        backgroundColor = theme.colors.surface
        valuesScrollView.showsHorizontalScrollIndicator = false
        valuesStack.axis = .horizontal
        valuesStack.alignment = .top

        valuesScrollView.addSubview(valuesStack)
        addSubview(labelColumn)
        addSubview(valuesScrollView)
        let separator = UIView()
        separator.backgroundColor = theme.colors.border
        addSubview(separator)
        [valuesStack, labelColumn, valuesScrollView, separator].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        NSLayoutConstraint.activate([
            valuesStack.topAnchor.constraint(equalTo: valuesScrollView.contentLayoutGuide.topAnchor),
            valuesStack.bottomAnchor.constraint(equalTo: valuesScrollView.contentLayoutGuide.bottomAnchor),
            valuesStack.leadingAnchor.constraint(equalTo: valuesScrollView.contentLayoutGuide.leadingAnchor),
            valuesStack.trailingAnchor.constraint(equalTo: valuesScrollView.contentLayoutGuide.trailingAnchor),
            valuesStack.heightAnchor.constraint(equalTo: valuesScrollView.frameLayoutGuide.heightAnchor),
            labelColumn.topAnchor.constraint(equalTo: topAnchor),
            labelColumn.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelColumn.bottomAnchor.constraint(equalTo: bottomAnchor),
            labelColumn.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth),
            valuesScrollView.topAnchor.constraint(equalTo: topAnchor),
            valuesScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            valuesScrollView.leadingAnchor.constraint(equalTo: labelColumn.trailingAnchor),
            valuesScrollView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: labelColumn.trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 0.5),
        ])
    }
}
#endif
