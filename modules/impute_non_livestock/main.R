##' # Imputation of Non-Livestock Commodities
##'
##' **Author: Josh Browning, Michael C. J. Kao**
##'
##' **Description:**
##'
##' This module imputes the triplet (input, productivity and output) for a given
##' non-livestock commodity.
##'
##' **Inputs:**
##'
##' * Production domain
##' * Complete Key Table
##' * Livestock Element Mapping Table
##' * Identity Formula Table
##'
##' **Flag assignment:**
##'
##' | Procedure | Observation Status Flag | Method Flag|
##' | --- | --- | --- |
##' | Balance by Production Identity | `<flag aggregation>` | i |
##' | Imputation | I | e |
##'
##' **Data scope**
##'
##' * GeographicAreaM49: All countries specified in the `Complete Key Table`.
##'
##' * measuredItemCPC: Depends on the session selection. If the selection is
##'   "session", then only items selected in the session will be imputed. If the
##'   selection is "all", then all the items listed in the `Complete Key Table`
##'   excluding the live stock item in the `Livestock Element Mapping Table`
##'   will be imputed.
##'
##' * measuredElement: Depends on the measuredItemCPC, all cooresponding
##'   elements in the `Identity Formula Table`.
##'
##' * timePointYears: All years specified in the `Complete Key Table`.
##'
##' ---

##' ## Initialisation
##'

##' Load the libraries
suppressMessages({
    library(faosws)
    library(faoswsUtil)
    library(faoswsFlag)
    library(faoswsImputation)
    library(faoswsProduction)
    library(faoswsProcessing)
    library(faoswsEnsure)
    library(magrittr)
    library(dplyr)
    library(sendmailR)
})

##' Set up for the test environment and parameters
R_SWS_SHARE_PATH <- Sys.getenv("R_SWS_SHARE_PATH")

if (CheckDebug()) {

    library(faoswsModules)
    SETTINGS <- ReadSettings("modules/impute_non_livestock/sws.yml")

    ## If you're not on the system, your settings will overwrite any others
    R_SWS_SHARE_PATH <- SETTINGS[["share"]]

    ## Define where your certificates are stored
    SetClientFiles(SETTINGS[["certdir"]])

    ## Get session information from SWS. Token must be obtained from web interface

    GetTestEnvironment(baseUrl = SETTINGS[["server"]],
                       token = SETTINGS[["token"]])
}

##' Get user specified imputation selection
imputationSelection <- swsContext.computationParams$imputation_selection
imputationTimeWindow <- swsContext.computationParams$imputation_timeWindow

stopifnot(imputationTimeWindow %in% c("all", "lastThree", "lastFive"))

##' Check the validity of the computational parameter
if(!imputationSelection %in% c("session", "all"))
    stop("Incorrect imputation selection specified")

FIX_OUTLIERS <- as.logical(swsContext.computationParams$fix_outliers)
THRESHOLD <- as.numeric(swsContext.computationParams$outliers_threshold)
AVG_YEARS <- 2009:2013

##' Get data configuration and session
sessionKey <- swsContext.datasets[[1]]
datasetConfig <- GetDatasetConfig(domainCode = sessionKey@domain,
                                 datasetCode = sessionKey@dataset)

##' Build processing parameters
processingParameters <-
    productionProcessingParameters(datasetConfig = datasetConfig)


lastYear=max(as.numeric(swsContext.computationParams$last_year))


##' Get the full imputation Datakey
completeImputationKey <- getCompleteImputationKey("production")

# Exclude 835, which is in QA but not in LIVE

completeImputationKey@dimensions$geographicAreaM49@keys <-
  setdiff(completeImputationKey@dimensions$geographicAreaM49@keys, "835")

completeImputationKey@dimensions$timePointYears@keys <-
    as.character(min(completeImputationKey@dimensions$timePointYears@keys):lastYear)


##' **NOTE (Michael): Since the animal/meat are currently imputed by the
##'                   imputed_slaughtered and synchronise slaughtered module, so
##'                   they should be excluded here.**
##'
liveStockItems <-
    getAnimalMeatMapping(R_SWS_SHARE_PATH = R_SWS_SHARE_PATH,
                         onlyMeatChildren = FALSE)
    liveStockItems = liveStockItems[,.(measuredItemParentCPC, measuredItemChildCPC)]
    liveStockItems = unlist(x = liveStockItems, use.names = FALSE)
    liveStockItems = unique(x = liveStockItems )


##' This is the complete list of items that are in the imputation list
nonLivestockImputationItems <-
    getQueryKey("measuredItemCPC", completeImputationKey) %>%
    setdiff(., liveStockItems)

##' These are the items selected by the users
sessionItems <-
    getQueryKey("measuredItemCPC", sessionKey) %>%
    intersect(., nonLivestockImputationItems)

##' Select the commodities based on the user input parameter
selectedItemCode <-
    switch(imputationSelection,
           "session" = sessionItems,
           "all" = nonLivestockImputationItems)

flagValidTable <- ReadDatatable("valid_flags")
stopifnot(nrow(flagValidTable) > 0)

##' ---
##' ## Perform Imputation
imputationResult <- data.table()

# lastYear=max(as.numeric(completeImputationKey@dimensions$timePointYears@keys))

# logConsole1=file("log.txt",open = "w")
# sink(file = logConsole1, append = TRUE, type = c( "message"))

##' Loop through the commodities to impute the items individually.
for (iter in seq(selectedItemCode)) {

        imputationProcess <- try({
            set.seed(070416)

            currentItem <- selectedItemCode[iter]


            ## Obtain the formula and remove indigenous and biological meat.
            ##
            ## NOTE (Michael): Biological and indigenous meat are currently
            ##                 removed, as they have incorrect data
            ##                 specification. They should be separate item with
            ##                 different item code rather than under different
            ##                 element under the meat code.
            formulaTable <-
                getProductionFormula(itemCode = currentItem) %>%
                removeIndigenousBiologicalMeat(formula = .)

            ## NOTE (Michael): Imputation should be performed on only 1 formula,
            ##                 if there are multiple formulas, they should be
            ##                 calculated based on the values imputed. For
            ##                 example, if one of the formula has production in
            ##                 tonnes while the other has production in
            ##                 kilo-gram, then we should impute the production
            ##                 in tonnes, then calculate the production in
            ##                 kilo-gram.
            if (nrow(formulaTable) > 1) {
                stop("Imputation should only use one formula")
            }

            ## Create the formula parameter list
            formulaParameters <-
                with(formulaTable,
                     productionFormulaParameters(datasetConfig = datasetConfig,
                                                 productionCode = output,
                                                 areaHarvestedCode = input,
                                                 yieldCode = productivity,
                                                 unitConversion = unitConversion)
                     )

            ## Update the item/element key according to the current commodity
            subKey <- completeImputationKey

            subKey@dimensions$measuredItemCPC@keys <- currentItem

            subKey@dimensions$measuredElement@keys <-
                with(formulaParameters,
                     c(productionCode, areaHarvestedCode, yieldCode))

            ## Start the imputation
            message("Imputation for item: ", currentItem, " (",  iter, " out of ",
                    length(selectedItemCode),")")

            ## Build imputation parameter
            imputationParameters <-
                with(formulaParameters,
                     getImputationParameters(productionCode = productionCode,
                                             areaHarvestedCode = areaHarvestedCode,
                                             yieldCode = yieldCode)
                     )

            ## Extract the data, and skip the imputation if the data contains no entry.
            extractedData <- GetData(subKey)

            ##extractedData= expandDatasetYears(extractedData, processingParameters,
            ##                                 swsContext.computationParams$startYear,swsContext.computationParams$endYear )

            if (nrow(extractedData) == 0) {
                message("Item : ", currentItem, " does not contain any data")
                next
            }

            ## Process the data.
            processedData <-
                extractedData %>%
                preProcessing(data = .)
               ## expandYear(data = .,
               ##            areaVar = processingParameters$areaVar,
               ##            elementVar = processingParameters$elementVar,
               ##            itemVar = processingParameters$itemVar,
               ##            valueVar = processingParameters$valueVar,
               ##            newYears= lastYear) %>%

          if (imputationTimeWindow == "all") {
            processedData <- removeNonProtectedFlag(processedData)
          } else if (imputationTimeWindow == "lastThree") {
            processedData <- removeNonProtectedFlag(processedData, keepDataUntil = (lastYear - 2))
          } else if (imputationTimeWindow == "lastFive") {
            processedData <- removeNonProtectedFlag(processedData, keepDataUntil = (lastYear - 4))
          }

          processedData <-
            denormalise(
              normalisedData = processedData,
              denormaliseKey = "measuredElement",
              fillEmptyRecords = TRUE
            )

          processedData <-
            createTriplet(
              data = processedData,
              formula = formulaTable
            )

   ##    if(imputationTimeWindow=="lastThree"){
   ##        processedDataLast=processedData[get(processingParameters$yearVar) %in% c(lastYear, lastYear-1, lastYear-2)]
   ##        processedDataAll=processedData[!get(processingParameters$yearVar) %in% c(lastYear, lastYear-1, lastYear-2)]
   ##                        processedDataLast=processProductionDomain(data = processedDataLast,
   ##                                processingParameters = processingParameters,
   ##                                formulaParameters = formulaParameters) %>%
   ##        ensureProductionInputs(data = .,
   ##                               processingParam = processingParameters,
   ##                               formulaParameters = formulaParameters,
   ##                               normalised = FALSE)
   ##        processedData=rbind(processedDataLast,processedDataAll)
   ##
   ##    }else{
   ##
   ##        processedData =  processProductionDomain(data = processedData,
   ##                                processingParameters = processingParameters,
   ##                                formulaParameters = formulaParameters) %>%
   ##            ensureProductionInputs(data = .,
   ##                                   processingParam = processingParameters,
   ##                                   formulaParameters = formulaParameters,
   ##                                   normalised = FALSE)
   ##
   ##              }
   ##
         ##imputationParameters$productionParams$plotImputation="prompt"
##------------------------------------------------------------------------------------------------------------------------

            ## We have to remove (M,-) from yield: since yield is usually computed ad identity,
            ## it results inusual that it exists a last available protected value different from NA and when we perform
            ## the function expandYear we risk to block the whole time series. I replace all the (M,-) in yield with
            ## (M,u) the triplet will be sychronized by the imputeProductionTriplet function.

            processedData[
              get(formulaParameters$yieldObservationFlag) == processingParameters$missingValueObservationFlag,
              ":="(
                c(formulaParameters$yieldMethodFlag),
                list(processingParameters$missingValueMethodFlag))
            ]

            processedData <- normalise(processedData)

            processedData <-
              expandYear(
                data       = processedData,
                areaVar    = processingParameters$areaVar,
                elementVar = processingParameters$elementVar,
                itemVar    = processingParameters$itemVar,
                valueVar   = processingParameters$valueVar,
                newYears   = lastYear
              )

            processedData <- denormalise(processedData, denormaliseKey = "measuredElement" )

##------------------------------------------------------------------------------------------------------------------------
            ## Perform imputation
            imputed <-
              imputeProductionTriplet(
                data                  = processedData,
                processingParameters  = processingParameters,
                formulaParameters     = formulaParameters,
                imputationParameters  = imputationParameters,
                completeImputationKey = completeImputationKey,
                imputationTimeWindow  = imputationTimeWindow,
                flagValidTable        = flagValidTable,
                FIX_OUTLIERS          = FIX_OUTLIERS,
                THRESHOLD             = THRESHOLD,
                AVG_YEARS             = AVG_YEARS
            )

##------------------------------------------------------------------------------------------------------------------------
          ## By now we did not have touched those situation in which production or areaHarvested are ZERO:
          ## we may have some yield different from zero even if productio or areaHarvested or the both are ZERO.
          ##
          ## I apply this modification to:
          ##    1) Production = zero
          ##    2) or AreaHarveste= zero
          ##    3) and non zero yield only.
          ##
            zeroProd <- imputed[, get(formulaParameters$productionValue) == 0 ]

            zeroreHArv <- imputed[, get(formulaParameters$areaHarvestedValue) == 0]

            nonZeroYield <- imputed[, (get(formulaParameters$yieldValue) != 0)]

            myfilter <- (zeroProd|zeroreHArv) & nonZeroYield

            imputed[myfilter, ":="(c(formulaParameters$yieldValue), list(0))]

            imputed[
              myfilter,
              ":="(
                c(formulaParameters$yieldObservationFlag),
                aggregateObservationFlag(
                  get(formulaParameters$productionObservationFlag),
                  get(formulaParameters$areaHarvestedObservationFlag)
                )
              )
            ]

            imputed[myfilter, ":="(c(formulaParameters$yieldMethodFlag),list(processingParameters$balanceMethodFlag))]

##------------------------------------------------------------------------------------------------------------------------

    ## Filter timePointYears for which it has been requested to compute imputations
    ## timeWindow= c(as.numeric(swsContext.computationParams$startYear):as.numeric(swsContext.computationParams$endYear))
    ## imputed= imputed[timePointYears %in% timeWindow,]

    ## Save the imputation back to the database.

    ##  Records containing invalid dates are
    ##  excluded, for example, South Sudan only came
    ##  into existence in 2011. Thus although we can
    ##  impute it, they should not be saved back to
    ##  the database.
            imputed <-
              removeInvalidDates(data = imputed, context = sessionKey) %>%
              ensureProductionOutputs(
                data = .,
                processingParameters = processingParameters,
                formulaParameters = formulaParameters,
                normalised = FALSE
              ) %>%
              normalise(.)

            #ensureProductionBalanced(imputed)
            #ensureProtectedData(imputed)

    ## Only data with method flag "i" for balanced,
    ## or flag combination (I, e) for imputed are
    ## saved back to the database.
    ##Also the new (M,-) data have to be sent back, series must be blocked!!!

            imputed <-
              imputed[
                (flagMethod == "i" | (flagObservationStatus == "I" & flagMethod == "e")) |
                  (flagObservationStatus == "M" & flagMethod == "-") |
                  (flagObservationStatus == "E" & flagMethod == "e"),]

            ##I should send to the data.base also the (M,-) value added in the last year in order to highlight that the series is closed.

            if (imputationTimeWindow == "lastThree") {
              imputed <- imputed[get(processingParameters$yearVar) %in% (lastYear - 0:2)]
            } else if (imputationTimeWindow == "lastFive") {
              imputed <- imputed[get(processingParameters$yearVar) %in% (lastYear - 0:4)]
            }

            imputed <- postProcessing(data = imputed)

            SaveData(domain = sessionKey@domain,
                     dataset = sessionKey@dataset,
                     data =  imputed)

        })

        ## Capture the items that failed
        if(inherits(imputationProcess, "try-error"))
            imputationResult <-
                rbind(imputationResult,
                      data.table(item = currentItem,
                                 error = imputationProcess[iter]))

}

##' ---
##' ## Return Message

if (nrow(imputationResult) > 0) {
    ## Initiate email
    from <- "sws@fao.org"
    to <- swsContext.userEmail
    subject <- "Imputation Result"
    body <- paste0("The following items failed, please inform the maintainer "
                  , "of the module")

    errorAttachmentName <- "non_livestock_imputation_result.csv"

    errorAttachmentPath <-
        paste0(R_SWS_SHARE_PATH, "/kao/", errorAttachmentName)

    write.csv(imputationResult, file = errorAttachmentPath,
              row.names = FALSE)

    errorAttachmentObject <- mime_part(x = errorAttachmentPath,
                                      name = errorAttachmentName)

    bodyWithAttachment <- list(body, errorAttachmentObject)

    sendmail(from = from, to = to, subject = subject, msg = bodyWithAttachment)

    stop("Production imputation incomplete, check following email to see where ",
         " it failed")
}

msg <- "Imputation Completed Successfully"

if (!CheckDebug()) {
  ## Initiate email
  from <- "sws@fao.org"
  to <- swsContext.userEmail
  subject <- "Crop-production imputation plugin has correctly run"
  body <- paste0("The plug-in has saved the Production imputation in your session. Session number: ",  sessionKey@sessionId)

  sendmail(from = from, to = to, subject = subject, msg = body)
}

print(msg)
