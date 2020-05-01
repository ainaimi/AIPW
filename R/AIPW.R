#' @title Augmented Inverse Probablity Weighting (AIPW)
#'
#' @description Define an R6Class aipw object
#'
#' @docType class
#'
#' @importFrom R6 R6Class
#'
#' @export
#'
#' @details create an AIPW object
#'
#' @return \code{AIPW} object
#'
#' @format \code{\link{R6Class}} object.
#'
AIPW <- R6::R6Class(
  "AIPW",
  portable = TRUE,
  public = list(
    #' @field n number of observations
    n = NULL,
    #' @field libs SuperLearner or sl3 libraries and their fitted objects
    libs =list(Q.SL.library=NULL,
               Q.fit = NULL,
               g.SL.library=NULL,
               g.fit = NULL),
    #' @field obs_est estimates for each observation to calculate average causal effects
    obs_est = list(mu0 = NULL,
                   mu1 = NULL,
                   mu = NULL,
                   pi = NULL,
                   aipw_eif1 = NULL,
                   aipw_eif0 = NULL),
    #' @field estimates risk difference, risk ratio, odds ratio and variance-covariance matrix for SE calcualtion
    estimates = list(RD = NULL,
                     RR = NULL,
                     OR = NULL,
                     sigma_covar = NULL),
    #' @field sl.fit a wrapper for fitting SuperLearner or sl3
    sl.fit = NULL,
    #' @field sl.predict a wrapper using \code{sl.fit} to predict
    sl.predict = NULL,
    #' @field result a matrix contains RD, RR and OR with their SE and 95%CI
    result = NULL,

    #' @description
    #' Create a new AIPW object.
    #'
    #' @param Y outcome
    #' @param A exposure
    #' @param W.Q covariates for outcome model
    #' @param W.g covariates for exposure model
    #' @param Q.SL.library SuperLearner libraries or sl3 learner object (Lrnr_base) for outcome model
    #' @param g.SL.library SuperLearner libraries or sl3 learner object (Lrnr_base) for exposure model
    #' @param k_split number of splitting: if k_split=1, no sample splitting;
    #'   if k_split>1, use similar technique of cross-validation
    #'   (e.g., k_split=5, use 4/5 of the data to estimate the 1/5 leftover data)
    #' @param verbose logical. Default = FALSE; when TRUE, show a text progress bar.
    #'
    #' @return A new `aipw` object.
    initialize = function(Y=NULL, A=NULL,W.Q=NULL, W.g=NULL,
                          Q.SL.library=NULL,g.SL.library=NULL,
                          k_split=1,verbose=FALSE){
      #save input into private fields
      private$Y=Y
      private$A=A
      private$Q.set=cbind(A, as.data.frame(W.Q))
      private$g.set=as.data.frame(W.g)
      private$k_split=k_split
      private$verbose=verbose
      #check data length
      if (!(length(private$Y)==length(private$A) & length(private$Y)==dim(private$Q.set)[1] & length(private$A)==dim(private$g.set)[1])){
        stop("Please check the dimension of the data")
      }
      #determine SuperLearner or sl3 and change accordingly
      if (is.character(Q.SL.library) & is.character(g.SL.library)) {
        if (any(grepl("SL.",Q.SL.library)) & any(grepl("SL.",g.SL.library))){
          #change wrapper functions
          self$sl.fit = function(Y, X, SL.library){
            fit <- SuperLearner(Y = Y, X = X, SL.library = SL.library, family="binomial")
            return(fit)
          }
          self$sl.predict = function(fit, newdata){
            pred <- as.numeric(predict(fit,newdata = newdata)$pred)
            return(pred)
          }
        } else{
          stop("Input Q.SL.library and/or g.SL.library is not a valid SuperLearner library")
        }
      } else if (any(class(Q.SL.library) == "Lrnr_base") & any(class(g.SL.library) == "Lrnr_base")) {
        #only using Stack in sl3 will return estimates of each library separately
        if (any(class(Q.SL.library) == "Stack") & any(class(g.SL.library) == "Stack")){
          warning("Only using sl3::Stack may cause problem. Please consider to use metalearner for the stacked libraries!")
        } else {
          #change wrapper functions
          self$sl.fit = function(X, Y, SL.library){
            dat <- data.frame(cbind(Y,X))
            dat_colnames <- colnames(dat)
            task <- sl3_Task$new(dat, covariates = colnames(dat)[-1],
                                 outcome = colnames(dat)[1], outcome_type = "binomial"
            )
            fit <- SL.library$train(task)
            return(fit)
          }
          self$sl.predict = function(fit, newdata){
            new_task <- sl3_Task$new(newdata, covariates = colnames(newdata))
            pred <- fit$predict(new_task)
            return(pred)
          }
        }
      } else {
        stop("Input Q.SL.library and/or g.SL.library is not a valid SuperLearner/sl3 library")
      }

      #input sl libraries
      self$libs$Q.SL.library=Q.SL.library
      self$libs$g.SL.library=g.SL.library

      #setup
      self$n <- length(private$Y)
      self$obs_est$mu0 <- rep(NA,self$n)
      self$obs_est$mu1 <- rep(NA,self$n)
      self$obs_est$mu <- rep(NA,self$n)
      self$obs_est$pi <- rep(NA,self$n)
    },
    #' @description
    #' Calculate average causal effects in RD, RR and OR
    #'
    calculate_result =function(){
      #create index for sample splitting
      k_index <- sample(rep(1:private$k_split,ceiling(self$n/private$k_split))[1:self$n],replace = F)
      #progress bar
      if (private$verbose){
        pb = utils::txtProgressBar(min = 0, max = length(private$k_split), initial = 0,style = 3)
      }

      #sample splitting
      for (i in 1:private$k_split){
        if (private$k_split==1){
          train_index <- validation_index <- k_index==i
        } else{
          train_index <- k_index!=i
          validation_index <- k_index==i
        }

        #split the sample
        #Q outcome set
        train_set.Q <- private$Q.set[train_index,]
        validation_set.Q <- private$Q.set[validation_index,]
        #g exposure set
        train_set.g <- data.frame(private$g.set[train_index,])
        validation_set.g <- data.frame(private$g.set[validation_index,])
        colnames(train_set.g)=colnames(validation_set.g)=colnames(private$g.set) #make to g df colnames consistent

        #Q model(outcome model: g-comp)
        #fit with train set
        self$libs$Q.fit <- self$sl.fit(Y = private$Y[train_index],
                                       X = train_set.Q,
                                       SL.library = self$libs$Q.SL.library)
        # predict on validation set
        self$obs_est$mu0[validation_index] <- self$sl.predict(self$libs$Q.fit,newdata=transform(validation_set.Q, A = 0)) #Q0_pred
        self$obs_est$mu1[validation_index]  <- self$sl.predict(self$libs$Q.fit,newdata=transform(validation_set.Q, A = 1)) #Q1_pred
        self$obs_est$mu[validation_index]  <- (self$obs_est$mu0[validation_index]*(1-private$A[validation_index]) +
                                                 self$obs_est$mu1[validation_index]*(private$A[validation_index])) #Q_pred

        #g model(exposure model: propensity score)
        # fit with train set
        self$libs$g.fit <- self$sl.fit(Y=private$A[train_index],
                                       X=train_set.g,
                                       SL.library = self$libs$g.SL.library)
        # predict on validation set
        self$obs_est$pi[validation_index]  <- self$sl.predict(self$libs$g.fit,newdata = validation_set.g)  #g_pred

        #progress bar
        if (private$verbose){
          utils::setTxtProgressBar(pb,i)
        }
      }

      #AIPW est
      self$obs_est$aipw_eif1 <- (as.numeric(private$A==1)/self$obs_est$pi)*(private$Y - self$obs_est$mu) + self$obs_est$mu1
      self$obs_est$aipw_eif0 <- (as.numeric(private$A==0)/self$obs_est$pi)*(private$Y - self$obs_est$mu) + self$obs_est$mu0

      Z_norm <- sqrt(self$n)

      ## risk difference
      self$estimates$RD <- private$get_RD(self$obs_est$aipw_eif1, self$obs_est$aipw_eif0, Z_norm)

      ## risk ratio
      self$estimates$sigma_covar <- matrix(c(stats::var(self$obs_est$aipw_eif0),
                                             stats::cov(self$obs_est$aipw_eif0,self$obs_est$aipw_eif1),
                                             stats::cov(self$obs_est$aipw_eif1,self$obs_est$aipw_eif0),
                                             stats::var(self$obs_est$aipw_eif1)),nrow=2)
      self$estimates$RR <- private$get_RR(self$obs_est$aipw_eif1,self$obs_est$aipw_eif0, self$estimates$sigma_covar, Z_norm)

      ## odds ratio
      self$estimates$OR <- private$get_OR(self$obs_est$aipw_eif1,self$obs_est$aipw_eif0, self$estimates$sigma_covar, Z_norm)

      self$result <- cbind(matrix(c(self$estimates$RD,self$estimates$RR,self$estimates$OR),nrow=3,byrow=T),self$n)
      colnames(self$result) <- c("Estimate","SE","95% LCL","95% UCL","N")
      row.names(self$result) <- c("Risk Difference","Risk Ratio", "Odds Ratio")
      if (private$verbose){
        cat("\n Done! \n")
      }
      print(self$result,digit=3)
    }
  ),
  private = list(
    #input
    Y=NULL,
    A=NULL,
    Q.set=NULL,
    g.set=NULL,
    k_split=NULL,
    verbose=NULL,
    #private methods
    #Use individaul estimates (obs_est$aipw_eif0 & obs_est$aipw_eif0 ) to calcualte RD, RR and OR with SE and 95CI%
    get_RD = function(aipw_eif1,aipw_eif0,Z_norm){
      est <- mean(aipw_eif1 - aipw_eif0)
      se <- stats::sd(aipw_eif1 - aipw_eif0)/Z_norm
      ci <- get_ci(est,se,ratio=F)
      output = c(est, se, ci)
      names(output) = c("Estimate","SE","95% LCL","95% UCL")
      return(output)
    },
    get_RR = function(aipw_eif1,aipw_eif0,sigma_covar,Z_norm){
      est <- mean(aipw_eif1)/mean(aipw_eif0)
      se <- ((sigma_covar[1,1]/(mean(aipw_eif0)^2)) -
               (2*sigma_covar[1,2]/(mean(aipw_eif1)*mean(aipw_eif0))) +
               (sigma_covar[2,2]/mean(aipw_eif1)^2) -
               (2*sigma_covar[1,2]/(mean(aipw_eif1)*mean(aipw_eif0))))/Z_norm
      ci <- get_ci(est,se,ratio=T)
      output = c(est, se, ci)
      names(output) = c("Estimate","SE","95% LCL","95% UCL")
      return(output)
    },
    get_OR = function(aipw_eif1,aipw_eif0,sigma_covar,Z_norm){
      est <- (mean(aipw_eif1)/(1-mean(aipw_eif1))) / (mean(aipw_eif0)/(1-mean(aipw_eif0)))
      se <- ((sigma_covar[1,1]/((mean(aipw_eif0)^2)*(mean(1-aipw_eif0)^2))) -
               (2*sigma_covar[1,2]/(mean(aipw_eif1)*mean(aipw_eif0)*mean(1-aipw_eif1)*mean(1-aipw_eif0))) +
               (sigma_covar[2,2]/((mean(aipw_eif1)^2)*(mean(1-aipw_eif1)^2))) -
               (2*sigma_covar[1,2]/(mean(aipw_eif1)*mean(aipw_eif0)
                                    *mean(1-aipw_eif1)*mean(1-aipw_eif0))))/Z_norm
      ci <- get_ci(est,se,ratio=T)
      output = c(est, se, ci)
      names(output) = c("Estimate","SE","95% LCL","95% UCL")
      return(output)
    }
  )
)