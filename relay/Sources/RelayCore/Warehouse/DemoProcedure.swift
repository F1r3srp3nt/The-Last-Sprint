import Foundation

/// Synthetic training procedure written for the Relay prototype.
///
/// DEMONSTRATION MATERIAL ONLY. This is not Holio documentation, is not based on any real
/// site's procedures, and must not be used to train real workers. Norwegian and Polish texts
/// were written for the demo and have not been reviewed by a professional translator.
public enum DemoProcedure {
    private static func t(_ en: String, _ nb: String, _ pl: String) -> LocalizedText {
        LocalizedText(["en": en, "nb": nb, "pl": pl])
    }

    public static let procedure = Procedure(
        id: "demo-inbound-pallet",
        title: t("Receiving an inbound pallet at Dock B",
                 "Mottak av innkommende pall ved port B",
                 "Przyjęcie palety przychodzącej przy rampie B"),
        version: "demo-0.1",
        sourceLanguage: "en",
        languages: ["en", "nb", "pl"],
        disclaimer: t(
            "Demonstration material created for the Relay prototype. Not official Holio documentation and not a real site procedure.",
            "Demonstrasjonsmateriale laget for Relay-prototypen. Ikke offisiell Holio-dokumentasjon og ikke en ekte arbeidsprosedyre.",
            "Materiał demonstracyjny przygotowany dla prototypu Relay. To nie jest oficjalna dokumentacja Holio ani rzeczywista procedura."),
        escalationContact: t("the shift lead", "skiftlederen", "kierownik zmiany"),
        steps: [
            ProcedureStep(
                id: "S1",
                title: t("Prepare and wait for the green dock light",
                         "Gjør deg klar og vent på grønt portlys",
                         "Przygotuj się i poczekaj na zielone światło rampy"),
                instruction: t(
                    "Put on safety shoes, a high-visibility vest and cut-resistant gloves. Wait at the yellow line until the dock light above Dock B is green.",
                    "Ta på vernesko, refleksvest og kuttsikre hansker. Vent ved den gule linjen til portlyset over port B er grønt.",
                    "Załóż obuwie ochronne, kamizelkę odblaskową i rękawice antyprzecięciowe. Czekaj przy żółtej linii, aż światło nad rampą B będzie zielone."),
                warnings: [
                    ProcedureWarning(id: "W1", severity: .critical, text: t(
                        "Never enter the dock area while a truck is reversing. Wait for the green dock light.",
                        "Gå aldri inn i portområdet mens en lastebil rygger. Vent på grønt portlys.",
                        "Nigdy nie wchodź na rampę, gdy ciężarówka cofa. Poczekaj na zielone światło.")),
                ]),
            ProcedureStep(
                id: "S2",
                title: t("Check the delivery against the expected list",
                         "Kontroller leveransen mot forventet liste",
                         "Sprawdź dostawę z listą oczekiwanych dostaw"),
                instruction: t(
                    "Scan the delivery note barcode with the handheld scanner. The scanner shows whether the delivery is on today's expected inbound list.",
                    "Skann strekkoden på følgeseddelen med håndskanneren. Skanneren viser om leveransen står på dagens liste over forventede leveranser.",
                    "Zeskanuj kod kreskowy z dokumentu dostawy skanerem ręcznym. Skaner pokaże, czy dostawa jest na dzisiejszej liście oczekiwanych dostaw."),
                warnings: [
                    ProcedureWarning(id: "W2", severity: .caution, text: t(
                        "If the delivery is not on the list, do not unload. Call the shift lead.",
                        "Hvis leveransen ikke står på listen, skal du ikke losse. Ring skiftlederen.",
                        "Jeśli dostawy nie ma na liście, nie rozładowuj. Zadzwoń do kierownika zmiany.")),
                ]),
            ProcedureStep(
                id: "S3",
                title: t("Inspect the pallet before moving it",
                         "Inspiser pallen før du flytter den",
                         "Obejrzyj paletę przed jej przeniesieniem"),
                instruction: t(
                    "Walk around the pallet. Look for torn stretch wrap, crushed corners, wet cardboard or leaks. Take a photo of any damage with the scanner.",
                    "Gå rundt pallen. Se etter revnet strekkfilm, knuste hjørner, våt papp eller lekkasjer. Ta bilde av eventuelle skader med skanneren.",
                    "Obejdź paletę dookoła. Sprawdź, czy folia nie jest rozdarta, rogi zgniecione, karton mokry lub czy nic nie wycieka. Zrób zdjęcie uszkodzeń skanerem."),
                warnings: [
                    ProcedureWarning(id: "W3", severity: .critical, text: t(
                        "If you see a leak or notice a strong smell, stop, step back and alert the shift lead. Do not touch the liquid.",
                        "Hvis du ser en lekkasje eller kjenner sterk lukt: stopp, gå unna og varsle skiftlederen. Ikke berør væsken.",
                        "Jeśli widzisz wyciek lub czujesz silny zapach: zatrzymaj się, odsuń i powiadom kierownika zmiany. Nie dotykaj cieczy.")),
                ]),
            ProcedureStep(
                id: "S4",
                title: t("Move the pallet to the inspection lane",
                         "Flytt pallen til inspeksjonsfeltet",
                         "Przewieź paletę na pole kontroli"),
                instruction: t(
                    "Use the hand pallet jack to move the pallet into the inspection lane marked with yellow lines. Lower the forks fully before leaving the pallet.",
                    "Bruk jekketralla til å flytte pallen inn i inspeksjonsfeltet merket med gule linjer. Senk gaflene helt før du forlater pallen.",
                    "Użyj ręcznego wózka paletowego, aby przewieźć paletę na pole kontroli oznaczone żółtymi liniami. Opuść całkowicie widły, zanim odejdziesz od palety."),
                warnings: [
                    ProcedureWarning(id: "W4", severity: .critical, text: t(
                        "Never stand or walk under a raised load.",
                        "Stå eller gå aldri under en hevet last.",
                        "Nigdy nie stój ani nie przechodź pod podniesionym ładunkiem.")),
                    ProcedureWarning(id: "W5", severity: .caution, text: t(
                        "The hand pallet jack is rated for 1,000 kg. Heavier pallets must be moved with powered equipment by a certified operator.",
                        "Jekketralla er godkjent for 1 000 kg. Tyngre paller skal flyttes med motorisert utstyr av en sertifisert fører.",
                        "Ręczny wózek paletowy ma udźwig 1000 kg. Cięższe palety musi przewieźć certyfikowany operator sprzętem z napędem.")),
                ]),
            ProcedureStep(
                id: "S5",
                title: t("Scan the pallet label",
                         "Skann pallelappen",
                         "Zeskanuj etykietę palety"),
                instruction: t(
                    "Scan the pallet label (SSCC). If the scanner asks for it, scan each carton label too. If a label cannot be read, type the number manually and mark it as \"label damaged\".",
                    "Skann pallelappen (SSCC). Hvis skanneren ber om det, skanner du også hver kartong. Hvis en lapp ikke kan leses, taster du nummeret manuelt og merker den som «skadet lapp».",
                    "Zeskanuj etykietę palety (SSCC). Jeśli skaner o to poprosi, zeskanuj też etykietę każdego kartonu. Jeśli etykiety nie da się odczytać, wpisz numer ręcznie i oznacz ją jako „uszkodzona etykieta”."),
                warnings: []),
            ProcedureStep(
                id: "S6",
                title: t("Count cartons and record differences",
                         "Tell kartonger og registrer avvik",
                         "Policz kartony i zapisz rozbieżności"),
                instruction: t(
                    "Count the cartons and compare with the quantity shown on the scanner. Record any shortage, surplus or damage in the scanner, with a photo.",
                    "Tell kartongene og sammenlign med antallet som vises på skanneren. Registrer mangler, overskudd eller skader i skanneren, med bilde.",
                    "Policz kartony i porównaj z ilością pokazaną na skanerze. Zapisz w skanerze każdy brak, nadwyżkę lub uszkodzenie, ze zdjęciem."),
                warnings: []),
            ProcedureStep(
                id: "S7",
                title: t("Label and place in staging",
                         "Merk og sett i buffersonen",
                         "Oznacz i odstaw do strefy buforowej"),
                instruction: t(
                    "Print the put-away label and attach it on two sides of the pallet. Leave the pallet in the staging area marked with the zone letter shown on the scanner.",
                    "Skriv ut plasseringslappen og fest den på to sider av pallen. Sett pallen i buffersonen merket med sonebokstaven som vises på skanneren.",
                    "Wydrukuj etykietę rozmieszczenia i przyklej ją na dwóch bokach palety. Zostaw paletę w strefie buforowej oznaczonej literą strefy pokazaną na skanerze."),
                warnings: [
                    ProcedureWarning(id: "W6", severity: .caution, text: t(
                        "Keep fire exits and yellow walkways clear. Never leave a pallet in a walkway.",
                        "Hold nødutganger og gule gangveier frie. Sett aldri en pall i en gangvei.",
                        "Utrzymuj wyjścia ewakuacyjne i żółte ciągi piesze wolne. Nigdy nie zostawiaj palety na przejściu.")),
                ]),
        ],
        facts: [
            ProcedureFact(id: "F1", kind: .answer,
                          keywords: ["glove", "gloves", "ppe", "vest", "shoes", "safety shoes", "hansker", "vernesko", "refleksvest", "rękawice", "kamizelk", "obuwie"],
                          answer: t("Wear safety shoes, a high-visibility vest and cut-resistant gloves.",
                                    "Bruk vernesko, refleksvest og kuttsikre hansker.",
                                    "Noś obuwie ochronne, kamizelkę odblaskową i rękawice antyprzecięciowe."),
                          supportingStepID: "S1"),
            ProcedureFact(id: "F2", kind: .answer,
                          keywords: ["light", "green", "red light", "reversing", "truck", "enter the dock", "lys", "grønt", "lastebil", "rygger", "światło", "zielone", "ciężarówka", "cofa"],
                          answer: t("Only enter the dock area when the dock light is green. Never enter while a truck is reversing.",
                                    "Gå bare inn i portområdet når portlyset er grønt. Gå aldri inn mens en lastebil rygger.",
                                    "Wchodź na rampę tylko przy zielonym świetle. Nigdy nie wchodź, gdy ciężarówka cofa."),
                          supportingStepID: "S1"),
            ProcedureFact(id: "F3", kind: .answer,
                          keywords: ["not on the list", "not on list", "expected list", "unexpected delivery", "delivery note", "ikke på listen", "følgeseddel", "nie ma na liście", "dokument dostawy"],
                          answer: t("If the delivery is not on the expected list, do not unload. Call the shift lead.",
                                    "Hvis leveransen ikke står på listen, skal du ikke losse. Ring skiftlederen.",
                                    "Jeśli dostawy nie ma na liście, nie rozładowuj. Zadzwoń do kierownika zmiany."),
                          supportingStepID: "S2"),
            ProcedureFact(id: "F4", kind: .answer,
                          keywords: ["leak", "leaking", "smell", "liquid", "spill", "wet", "lekkasje", "lukt", "væske", "wyciek", "zapach", "ciecz"],
                          answer: t("Stop, step back and alert the shift lead. Do not touch the liquid.",
                                    "Stopp, gå unna og varsle skiftlederen. Ikke berør væsken.",
                                    "Zatrzymaj się, odsuń i powiadom kierownika zmiany. Nie dotykaj cieczy."),
                          supportingStepID: "S3"),
            ProcedureFact(id: "F5", kind: .answer,
                          keywords: ["damage", "damaged pallet", "torn", "crushed", "photo of damage", "skade", "revnet", "uszkodz", "zgniecione"],
                          answer: t("Look for torn wrap, crushed corners, wet cardboard or leaks, and photograph any damage with the scanner.",
                                    "Se etter revnet strekkfilm, knuste hjørner, våt papp eller lekkasjer, og ta bilde av skader med skanneren.",
                                    "Sprawdź rozdartą folię, zgniecione rogi, mokry karton lub wycieki i sfotografuj uszkodzenia skanerem."),
                          supportingStepID: "S3"),
            ProcedureFact(id: "F6", kind: .answer,
                          keywords: ["weight", "heavy", "kg", "how much", "limit", "capacity", "pallet jack", "vekt", "tung", "jekketralle", "waga", "ciężk", "udźwig", "wózek"],
                          answer: t("The hand pallet jack is rated for 1,000 kg. Heavier pallets must be moved with powered equipment by a certified operator.",
                                    "Jekketralla er godkjent for 1 000 kg. Tyngre paller skal flyttes med motorisert utstyr av en sertifisert fører.",
                                    "Ręczny wózek paletowy ma udźwig 1000 kg. Cięższe palety musi przewieźć certyfikowany operator sprzętem z napędem."),
                          supportingStepID: "S4"),
            ProcedureFact(id: "F7", kind: .answer,
                          keywords: ["raised load", "under the load", "forks", "lower", "hevet last", "gaflene", "podniesion", "widły"],
                          answer: t("Never stand or walk under a raised load, and lower the forks fully before leaving the pallet.",
                                    "Stå eller gå aldri under en hevet last, og senk gaflene helt før du forlater pallen.",
                                    "Nigdy nie stój pod podniesionym ładunkiem i całkowicie opuść widły, zanim odejdziesz od palety."),
                          supportingStepID: "S4"),
            ProcedureFact(id: "F8", kind: .answer,
                          keywords: ["unreadable", "cannot read", "can't read", "label damaged", "damaged label", "manually", "sscc", "kan ikke leses", "manuelt", "nieczyteln", "ręcznie", "uszkodzona etykieta"],
                          answer: t("Type the number manually and mark the label as \"label damaged\".",
                                    "Tast nummeret manuelt og merk lappen som «skadet lapp».",
                                    "Wpisz numer ręcznie i oznacz etykietę jako „uszkodzona etykieta”."),
                          supportingStepID: "S5"),
            ProcedureFact(id: "F9", kind: .answer,
                          keywords: ["count", "shortage", "missing carton", "surplus", "too many", "quantity", "telle", "antall", "mangler", "overskudd", "policz", "brak", "nadwyżk", "ilość"],
                          answer: t("Count the cartons, compare with the scanner, and record any shortage, surplus or damage with a photo.",
                                    "Tell kartongene, sammenlign med skanneren og registrer mangler, overskudd eller skader med bilde.",
                                    "Policz kartony, porównaj ze skanerem i zapisz braki, nadwyżki lub uszkodzenia ze zdjęciem."),
                          supportingStepID: "S6"),
            ProcedureFact(id: "F10", kind: .answer,
                          keywords: ["where do i put", "where should", "staging", "zone", "zone letter", "put-away", "put away", "buffersone", "sonebokstav", "strefa", "buforow", "gdzie"],
                          answer: t("Attach the put-away label on two sides and leave the pallet in the staging area with the zone letter shown on the scanner.",
                                    "Fest plasseringslappen på to sider og sett pallen i buffersonen med sonebokstaven som vises på skanneren.",
                                    "Przyklej etykietę na dwóch bokach i zostaw paletę w strefie buforowej z literą pokazaną na skanerze."),
                          supportingStepID: "S7"),
            ProcedureFact(id: "F11", kind: .answer,
                          keywords: ["walkway", "fire exit", "emergency exit", "gangvei", "nødutgang", "przejście", "wyjście ewakuacyjne"],
                          answer: t("Keep fire exits and yellow walkways clear. Never leave a pallet in a walkway.",
                                    "Hold nødutganger og gule gangveier frie. Sett aldri en pall i en gangvei.",
                                    "Utrzymuj wyjścia ewakuacyjne i żółte przejścia wolne. Nigdy nie zostawiaj palety na przejściu."),
                          supportingStepID: "S7"),
            // Explicitly out of scope: the procedure says nothing about these, so Relay escalates.
            ProcedureFact(id: "X1", kind: .outOfScope,
                          keywords: ["frozen", "chilled", "cold", "temperature", "fridge", "freezer", "frossen", "kjøl", "temperatur", "mrożon", "chłodz", "temperatura"],
                          answer: t("This procedure does not cover temperature-controlled goods.",
                                    "Denne prosedyren dekker ikke temperaturregulerte varer.",
                                    "Ta procedura nie obejmuje towarów wymagających kontroli temperatury."),
                          supportingStepID: nil),
            ProcedureFact(id: "X2", kind: .outOfScope,
                          keywords: ["forklift", "truck licence", "license", "certificate", "certified operator", "drive the", "truckførerbevis", "truckfører", "sertifikat", "wózek widłowy", "uprawnienia", "certyfikat"],
                          answer: t("This procedure does not cover operating powered equipment or how to get certified.",
                                    "Denne prosedyren dekker ikke kjøring av motorisert utstyr eller sertifisering.",
                                    "Ta procedura nie obejmuje obsługi sprzętu z napędem ani zdobywania uprawnień."),
                          supportingStepID: nil),
        ]
    )
}
