import Foundation

/// Une valeur écrite dans un champ de document.
///
/// Distinct de ``QueryValue`` à dessein : on peut **écrire** un horodatage serveur ou
/// supprimer un champ, on ne peut pas les **interroger**. Deux domaines, deux types.
public enum DocumentField: Sendable, Equatable {

    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case array([DocumentField])
    case null

    /// **L'heure du serveur**, résolue à l'écriture.
    ///
    /// À préférer systématiquement à `.date(.now)` pour tout ce qui ordonne des
    /// événements : l'horloge d'un appareil peut avoir des minutes d'écart, et deux
    /// appareils désaccordés produiraient un ordre faux.
    ///
    /// > Entre l'écriture locale et la réponse du serveur, le champ vaut `null`. Déclarez
    /// > donc la propriété correspondante en **`Date?`** — un `Date` non optionnel fera
    /// > échouer le décodage pendant cette fenêtre.
    case serverTimestamp

    /// **Ajoute** au nombre déjà en place, côté serveur, sans lire d'abord.
    ///
    /// C'est ce qui permet à deux appareils d'incrémenter un compteur en même temps sans
    /// s'écraser — chacun ajoute son delta.
    ///
    /// > **Une écriture qui en contient une n'est jamais rejouée.** Contrairement au reste
    /// > du module, un incrément est **relatif** : le rejouer après un timeout douteux
    /// > compterait deux fois. Le serveur l'a peut-être appliqué avant de ne pas répondre.
    case increment(Double)

    /// Ajoute des éléments à un tableau, sans doublon, côté serveur.
    ///
    /// Idempotent : ajouter deux fois le même élément ne change rien, donc rejouable.
    case arrayUnion([DocumentField])

    /// Retire des éléments d'un tableau, côté serveur.
    ///
    /// Idempotent, pour la même raison.
    case arrayRemove([DocumentField])

    /// Retire le champ du document, au lieu de le mettre à `null`.
    ///
    /// La différence compte : un champ absent ne remonte pas dans une requête
    /// `whereField(_, isEqualTo: NSNull())`, un champ nul si.
    case deleteField
}

public extension DocumentField {
    /// Un incrément entier.
    static func increment(_ amount: Int) -> DocumentField { .increment(Double(amount)) }

    /// Indique si l'écriture de ce champ dépend de l'état courant du serveur.
    ///
    /// Seul l'incrément l'est : c'est ce qui interdit de le rejouer.
    var isRelative: Bool {
        switch self {
        case .increment: true
        case .string, .int, .double, .bool, .date, .array, .null,
             .serverTimestamp, .deleteField, .arrayUnion, .arrayRemove:
            false
        }
    }
}

extension DocumentField: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension DocumentField: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension DocumentField: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension DocumentField: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension DocumentField: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension DocumentField: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: DocumentField...) { self = .array(elements) }
}
