import Foundation

/// One language's version of `QualityCorpus`: the same 12 file names and topics, written the way a
/// native speaker would write the notes and search for them. Eight of the 16 queries share no
/// content word with their answer (pure meaning match). The other eight are keywords from it.
struct LanguageCorpus {
    let tag: String
    let documents: [String: String]
    let queries: [(String, String)]
}

// swiftlint:disable line_length
enum MultilingualCorpus {
    static let spanish = LanguageCorpus(
        tag: "es",
        documents: [
            "release.md": "# Publicar una versión\nEtiqueta el commit y el flujo de trabajo compila la app. Firma el paquete y lo envía a Apple para su notarización antes de subirlo.",
            "backup.md": "# Copias de seguridad\nCopia tus notas a un disco externo cada semana. Guarda otra copia fuera de casa por si hay un incendio o un robo.",
            "password.md": "# Contraseñas\nUsa un gestor de contraseñas. No repitas la misma clave en varias webs y activa la verificación en dos pasos.",
            "garden.md": "# Huerto\nRiega los tomates a primera hora de la mañana. Ata los tallos a una estaca y quita los brotes laterales pequeños.",
            "budget.md": "# Presupuesto\nAnota los gastos del mes en una hoja de cálculo. Aparta una parte de cada nómina para ahorrar antes de pagar las facturas.",
            "travel.md": "# Viaje a Lisboa\nReserva el vuelo en marzo. Nos alojaremos junto a la línea del tranvía antiguo y haremos una excursión a la costa.",
            "cooking.md": "# Cenas entre semana\nAsa las verduras con aceite de oliva y ajo. Cuece la pasta al dente y mézclala con la salsa.",
            "meeting.md": "# Reunión de equipo\nOrden del día: revisión del sprint, errores abiertos, plan de contratación. Las tareas pendientes van al tablero compartido tras la llamada.",
            "bike.md": "# Arreglar la bici\nLa rueda trasera pierde aire poco a poco. Parchea la cámara y revisa las pastillas de freno antes de la próxima salida.",
            "reading.md": "# Lista de lectura\nUna novela sobre un farero, una historia de la imprenta y una guía breve del canto de las aves.",
            "sleep.md": "# Dormir\nAcuéstate a la misma hora cada noche. Evita las pantallas y el café por la tarde para descansar mejor.",
            "api.md": "# Diseño de API\nDevuelve códigos de error claros. Versiona los endpoints y documenta cada campo del cuerpo de la respuesta.",
        ],
        queries: [
            ("cómo sacamos una nueva edición del programa", "release.md"),
            ("proteger mis documentos si se estropea el ordenador", "backup.md"),
            ("evitar que me hackeen las cuentas", "password.md"),
            ("cuándo dar agua a las hortalizas", "garden.md"),
            ("controlar mis finanzas personales", "budget.md"),
            ("qué preparo para comer hoy", "cooking.md"),
            ("tengo un neumático desinflado", "bike.md"),
            ("me cuesta conciliar el sueño", "sleep.md"),
            ("tranvía", "travel.md"),
            ("orden del día", "meeting.md"),
            ("farero", "reading.md"),
            ("endpoints", "api.md"),
            ("verificación en dos pasos", "password.md"),
            ("pastillas de freno", "bike.md"),
            ("pasta salsa", "cooking.md"),
            ("disco externo", "backup.md"),
        ]
    )

    static let french = LanguageCorpus(
        tag: "fr",
        documents: [
            "release.md": "# Publier une version\nÉtiquetez le commit, puis le workflow compile l'application. Il signe l'archive et l'envoie à Apple pour la notarisation avant la mise en ligne.",
            "backup.md": "# Sauvegardes\nCopiez vos notes sur un disque externe chaque semaine. Gardez une autre copie hors de chez vous en cas d'incendie ou de vol.",
            "password.md": "# Mots de passe\nUtilisez un gestionnaire de mots de passe. Ne réutilisez jamais le même identifiant sur plusieurs sites et activez la double authentification.",
            "garden.md": "# Potager\nArrosez les tomates tôt le matin. Attachez les tiges à un tuteur et supprimez les petits gourmands.",
            "budget.md": "# Budget\nNotez les dépenses du mois dans un tableur. Mettez de côté une partie de chaque salaire avant de payer les factures.",
            "travel.md": "# Voyage à Lisbonne\nRéservez le vol en mars. Nous logerons près de la ligne du vieux tramway et ferons une excursion jusqu'à la côte.",
            "cooking.md": "# Dîners de semaine\nFaites rôtir les légumes avec de l'huile d'olive et de l'ail. Cuisez les pâtes al dente et mélangez-les à la sauce.",
            "meeting.md": "# Réunion d'équipe\nOrdre du jour : revue du sprint, bugs ouverts, plan de recrutement. Les actions vont sur le tableau partagé après l'appel.",
            "bike.md": "# Réparer le vélo\nLe pneu arrière se dégonfle lentement. Réparez la chambre à air et vérifiez les plaquettes de frein avant la prochaine sortie.",
            "reading.md": "# Liste de lecture\nUn roman sur un gardien de phare, une histoire de l'imprimerie et un petit guide des chants d'oiseaux.",
            "sleep.md": "# Sommeil\nCouchez-vous à la même heure chaque soir. Évitez les écrans et le café en fin de journée pour mieux vous reposer.",
            "api.md": "# Conception d'API\nRenvoyez des codes d'erreur clairs. Versionnez les endpoints et documentez chaque champ du corps de la réponse.",
        ],
        queries: [
            ("comment livrer une nouvelle édition du logiciel", "release.md"),
            ("protéger mes documents contre une panne", "backup.md"),
            ("empêcher le piratage de mes comptes", "password.md"),
            ("quand donner de l'eau aux plantes", "garden.md"),
            ("mieux gérer mon argent", "budget.md"),
            ("que préparer pour le repas aujourd'hui", "cooking.md"),
            ("crevaison sur ma bicyclette", "bike.md"),
            ("j'ai du mal à m'endormir", "sleep.md"),
            ("tramway", "travel.md"),
            ("ordre du jour", "meeting.md"),
            ("gardien de phare", "reading.md"),
            ("endpoints", "api.md"),
            ("double authentification", "password.md"),
            ("plaquettes de frein", "bike.md"),
            ("pâtes sauce", "cooking.md"),
            ("disque externe", "backup.md"),
        ]
    )

    static let german = LanguageCorpus(
        tag: "de",
        documents: [
            "release.md": "# Release veröffentlichen\nTagge den Commit, dann baut der Workflow die App. Er signiert das Archiv und schickt es vor dem Upload zur Notarisierung an Apple.",
            "backup.md": "# Datensicherung\nKopiere deine Notizen jede Woche auf eine externe Festplatte. Bewahre eine weitere Kopie außer Haus auf, falls es brennt oder eingebrochen wird.",
            "password.md": "# Passwörter\nNutze einen Passwortmanager. Verwende nie dasselbe Login auf mehreren Seiten und aktiviere die Zwei-Faktor-Authentifizierung.",
            "garden.md": "# Garten\nGieße die Tomaten früh am Morgen. Binde die Triebe an einen Stab und entferne die kleinen Geiztriebe.",
            "budget.md": "# Haushaltsplan\nHalte die Monatsausgaben in einer Tabelle fest. Lege von jedem Gehalt einen Teil zurück, bevor du die Rechnungen bezahlst.",
            "travel.md": "# Reise nach Lissabon\nBuche den Flug im März. Wir wohnen in der Nähe der alten Straßenbahnlinie und machen einen Tagesausflug an die Küste.",
            "cooking.md": "# Schnelle Feierabendküche\nRöste das Gemüse mit Olivenöl und Knoblauch. Koche die Nudeln bissfest und vermische sie mit der Soße.",
            "meeting.md": "# Teamrunde\nTagesordnung: Sprint-Review, offene Bugs, Einstellungsplan. Aufgaben landen nach dem Anruf auf dem gemeinsamen Board.",
            "bike.md": "# Fahrrad reparieren\nDer Hinterreifen verliert langsam Luft. Flicke den Schlauch und prüfe die Bremsbeläge vor der nächsten Fahrt.",
            "reading.md": "# Leseliste\nEin Roman über einen Leuchtturmwärter, eine Geschichte des Buchdrucks und ein kurzer Führer zu Vogelstimmen.",
            "sleep.md": "# Schlaf\nGeh jeden Abend zur gleichen Zeit ins Bett. Meide Bildschirme und Kaffee am späten Nachmittag, damit du besser ruhst.",
            "api.md": "# API-Design\nGib klare Fehlercodes zurück. Versioniere die Endpunkte und dokumentiere jedes Feld im Antworttext.",
        ],
        queries: [
            ("wie bringen wir eine neue Fassung raus", "release.md"),
            ("wie schütze ich meine Texte, wenn der Rechner kaputtgeht", "backup.md"),
            ("Konten vor Hackern schützen", "password.md"),
            ("wann bewässere ich meine Pflanzen", "garden.md"),
            ("wie komme ich mit meinem Geld besser klar", "budget.md"),
            ("was gibt es heute zu essen", "cooking.md"),
            ("Panne mit dem Zweirad", "bike.md"),
            ("ich liege nachts stundenlang wach", "sleep.md"),
            ("Straßenbahn", "travel.md"),
            ("Tagesordnung", "meeting.md"),
            ("Leuchtturmwärter", "reading.md"),
            ("Endpunkte", "api.md"),
            ("Zwei-Faktor", "password.md"),
            ("Bremsbeläge", "bike.md"),
            ("Nudeln Soße", "cooking.md"),
            ("externe Festplatte", "backup.md"),
        ]
    )

    static let italian = LanguageCorpus(
        tag: "it",
        documents: [
            "release.md": "# Pubblicare una versione\nEtichetta il commit e il workflow compila l'app. Firma l'archivio e lo invia ad Apple per la notarizzazione prima del caricamento.",
            "backup.md": "# Backup\nCopia gli appunti su un disco esterno ogni settimana. Tieni un'altra copia fuori casa in caso di incendio o furto.",
            "password.md": "# Password\nUsa un gestore di password. Non riutilizzare mai lo stesso accesso su più siti e attiva l'autenticazione a due fattori.",
            "garden.md": "# Orto\nInnaffia i pomodori la mattina presto. Lega i fusti a un tutore e togli i piccoli germogli laterali.",
            "budget.md": "# Bilancio familiare\nSegna le spese del mese in un foglio di calcolo. Metti da parte una quota di ogni stipendio prima di pagare le bollette.",
            "travel.md": "# Viaggio a Lisbona\nPrenota il volo a marzo. Alloggeremo vicino alla vecchia linea del tram e faremo una gita in giornata fino alla costa.",
            "cooking.md": "# Cene infrasettimanali\nArrostisci le verdure con olio d'oliva e aglio. Cuoci la pasta al dente e condiscila con il sugo.",
            "meeting.md": "# Riunione del team\nOrdine del giorno: revisione dello sprint, bug aperti, piano di assunzioni. Le azioni vanno sulla bacheca condivisa dopo la chiamata.",
            "bike.md": "# Riparare la bici\nLa gomma posteriore si sgonfia lentamente. Rattoppa la camera d'aria e controlla le pastiglie dei freni prima della prossima uscita.",
            "reading.md": "# Lista di lettura\nUn romanzo su un guardiano del faro, una storia della stampa e una breve guida ai canti degli uccelli.",
            "sleep.md": "# Sonno\nVai a letto sempre alla stessa ora ogni sera. Evita schermi e caffè nel tardo pomeriggio per riposare meglio.",
            "api.md": "# Progettare un'API\nRestituisci codici di errore chiari. Versiona gli endpoint e documenta ogni campo nel corpo della risposta.",
        ],
        queries: [
            ("come rilasciamo una nuova edizione del programma", "release.md"),
            ("come proteggere i miei file da un guasto", "backup.md"),
            ("evitare che mi violino gli account", "password.md"),
            ("quando dare acqua alle piante", "garden.md"),
            ("gestire meglio i soldi", "budget.md"),
            ("cosa preparo per pranzo", "cooking.md"),
            ("ho lo pneumatico a terra", "bike.md"),
            ("faccio fatica ad addormentarmi", "sleep.md"),
            ("tram", "travel.md"),
            ("ordine del giorno", "meeting.md"),
            ("faro", "reading.md"),
            ("endpoint", "api.md"),
            ("due fattori", "password.md"),
            ("pastiglie dei freni", "bike.md"),
            ("pasta sugo", "cooking.md"),
            ("disco esterno", "backup.md"),
        ]
    )

    static let portuguese = LanguageCorpus(
        tag: "pt",
        documents: [
            "release.md": "# Publicar uma versão\nMarca o commit e o workflow compila a app. Assina o pacote e envia-o à Apple para notarização antes do carregamento.",
            "backup.md": "# Cópias de segurança\nCopia as tuas notas para um disco externo todas as semanas. Guarda outra cópia fora de casa, para o caso de incêndio ou roubo.",
            "password.md": "# Palavras-passe\nUsa um gestor de palavras-passe. Nunca repitas o mesmo acesso em vários sites e ativa a autenticação em dois passos.",
            "garden.md": "# Horta\nRega os tomateiros logo de manhã cedo. Prende os caules a uma estaca e tira os rebentos laterais pequenos.",
            "budget.md": "# Orçamento\nRegista as despesas do mês numa folha de cálculo. Põe de parte uma fatia de cada salário antes de pagar as contas.",
            "travel.md": "# Viagem a Lisboa\nReserva o voo em março. Vamos ficar perto da linha do elétrico antigo e fazer uma excursão até à costa.",
            "cooking.md": "# Jantares do dia a dia\nAssa os legumes com azeite e alho. Coze a massa al dente e envolve-a no molho.",
            "meeting.md": "# Reunião de equipa\nOrdem de trabalhos: revisão do sprint, bugs abertos, plano de contratações. As tarefas seguem para o quadro partilhado depois da chamada.",
            "bike.md": "# Arranjar a bicicleta\nO pneu de trás está a esvaziar devagar. Remenda a câmara de ar e verifica as pastilhas dos travões antes do próximo passeio.",
            "reading.md": "# Lista de leitura\nUm romance sobre um faroleiro, uma história da imprensa e um pequeno guia dos cantos das aves.",
            "sleep.md": "# Sono\nDeita-te sempre à mesma hora, todas as noites. Evita ecrãs e café ao fim da tarde para descansares melhor.",
            "api.md": "# Desenho de API\nDevolve códigos de erro claros. Versiona os endpoints e documenta cada campo do corpo da resposta.",
        ],
        queries: [
            ("como lançamos uma edição nova do programa", "release.md"),
            ("proteger os meus ficheiros se o computador avariar", "backup.md"),
            ("impedir que pirateiem as minhas contas", "password.md"),
            ("quando dar água às plantas", "garden.md"),
            ("gerir melhor o dinheiro", "budget.md"),
            ("o que preparo para comer hoje", "cooking.md"),
            ("a minha roda está em baixo", "bike.md"),
            ("custa-me adormecer", "sleep.md"),
            ("elétrico", "travel.md"),
            ("ordem de trabalhos", "meeting.md"),
            ("faroleiro", "reading.md"),
            ("endpoints", "api.md"),
            ("dois passos", "password.md"),
            ("pastilhas dos travões", "bike.md"),
            ("massa molho", "cooking.md"),
            ("disco externo", "backup.md"),
        ]
    )

    static let all = [spanish, french, german, italian, portuguese]
}

// swiftlint:enable line_length
