tsglm.meanfit <- function(ts, model, xreg, link, score=TRUE, info=c("score", "none", "hessian", "sandwich"), init.method=c("marginal", "iid", "firstobs", "zero"), init.drop=FALSE, epsilon=1e-06, slackvar=1e-06, start.control=list(), final.control=list(), inter.control=NULL){
  ##############
  #Checks and preparations: 
  cl <- match.call()
  durations <- c(start=NA, inter=NA, final=NA, total=NA)
  begin_total <- proc.time()["elapsed"]
  model_names <- c("past_obs", "past_mean", "external")
  if(!all(names(model) %in% model_names)) stop("Argument 'model' must only contain list elements named \"past_obs\", \"past_mean\"\nand \"external\".")
  model <- model[model_names]
  names(model) <- model_names
  if(is.null(xreg)) xreg <- matrix(0, nrow=length(ts), ncol=0) else xreg <- as.matrix(xreg)
  if(link=="identity") if(any(xreg<0)) stop("The covariates given in argument 'xreg' must be nonnegative for a model with\nthe identity link function. Choose a model with the logarithmic link function\ninstead or shift the values of the respective covariate(s) by a constant such that\nthey become nonnegative.")
  if(length(model$external)==0) model$external <- rep(FALSE, ncol(xreg)) else model$external <- as.logical(model$external) #the default value for model$external is FALSE (i.e. an internal covariate effect)
  if(length(model$external)==1) model$external <-  rep(model$external, ncol(xreg)) else model$external <- as.logical(model$external) #if only one value for model$external is provided, this is used for all covariates
  if(is.list(ts)) stop("Argument 'ts' has to be a vector") 
  if(any(is.na(ts)) || any(is.na(xreg))) stop("Cannot make estimation with missing values in time series or covariates")
  stopifnot( #Are the arguments valid?
    model$past_obs%%1==0,
    model$past_mean%%1==0,
    length(ts)==nrow(xreg),    
    length(model$external)==ncol(xreg)
  )   
  stopifnot( #Are the arguments valid?
    is.list(start.control),
    is.null(final.control) || is.list(final.control)
  )  
  info <- match.arg(info)
  if(is.null(final.control) || is.null(final.control$constrained)) slackvar <- 0
  n <- length(ts)
  p <- length(model$past_obs)
  P <- seq(along=numeric(p)) #sequence 1:p if p>0 and NULL otherwise
  p_max <- max(model$past_obs, 0)
  q <- length(model$past_mean)
  Q <- seq(along=numeric(q)) #sequence 1:q if q>0 and NULL otherwise
  q_max <- max(model$past_mean, 0)
  r <- ncol(xreg)
  R <- seq(along=numeric(r)) #sequence 1:r if r>0 and NULL otherwise
  if(p==0 & q>0) warning("Without dependence on past observations the dependence on past values of the\nlinear predictor has no effect. Choose the model wisely.")
  parameternames <- tsglm.parameternames(model=model, xreg=xreg)
  start_default <- list(method="iid", use=Inf)
  if(!all(names(start.control) %in% c(names(start_default), "intercept", "past_obs", "past_mean", "xreg"))) stop("There are unknown list elements in argument 'start.control'")
  start_default[names(start.control)] <- start.control #options given by user override the default
  start.control <- start_default #use these options in the following
  if(!is.null(final.control)){
    final_default <- list(constrained=list(), optim.method="BFGS", optim.control=list(maxit=100, reltol=1e-11))
    final_default[names(final.control)] <- final.control  
    final.control <- final_default
    if(!all(names(final.control) %in% names(final_default))) stop("There are unknown list elements in argument 'final.control'")
  }
  if(!is.null(inter.control)){
    inter_default <- list(constrained=list(outer.iterations=5), optim.method="Nelder-Mead", optim.control=list(maxit=20, reltol=1e-8))
    inter_default[names(inter.control)] <- inter.control  
    inter.control <- inter_default
    if(!all(names(inter.control)%in%names(inter_default))) stop("There are unknown list elements in argument 'inter.control'")
  }
  ##############

  ##############
  #Starting value:
  begin_start <- proc.time()["elapsed"]
  param_start <- tsglm.startfit(ts=ts, model=model, xreg=xreg, start.control=start.control, link=link)

  # # # # # # #
  if(!is.null(final.control$constrained)){ #in case of constrained optimization the starting values are a projection of the start estimation into the parameter space
    if(link=="identity"){
      #Transformation to a stationary solution of an INGARCH process:
      marginalmean <- param_start$intercept/(1-sum(param_start$past_obs)-sum(param_start$past_mean))
      param_start$past_obs <- pmax(param_start$past_obs, rep(epsilon, p)) #beta_i in [0+epsilon,Inf)
      param_start$past_mean <- pmax(param_start$past_mean, rep(epsilon, q)) #alpha_i in [0+epsilon,Inf)
      total <- sum(param_start$past_obs)+sum(param_start$past_mean)
      if(total > 1-epsilon-slackvar){ #Shrink the parameters to fulfill the stationarity condition if necessary:
        shrinkage_factor <- (1-slackvar-epsilon)/total #chosen, such that total_new = 1-slackvar-epsilon for total_new the sum of the alpha's and beta's after shrinkage
        param_start$past_mean <- param_start$past_mean*shrinkage_factor
        param_start$past_obs <- param_start$past_obs*shrinkage_factor
        #Note: This way former negative values, which have been set to epsilon before, become lower than epsilon. However, this will probably happen rarely (if at all) in practice.
      }
      if(start.control$method %in% c("MM", "CSS", "ML", "CSS-ML", "GLM")) param_start$intercept <- marginalmean*(1-sum(param_start$past_obs)-sum(param_start$past_mean)) #replaces the previous value of the intercept by one which results, together with the corrected dependence parameters, to the same marginal mean as before the correction step
      param_start$intercept <- max(param_start$intercept, slackvar+epsilon)
      param_start$xreg <- pmax(param_start$xreg, epsilon)
    }
    if(link=="log"){
      #Transformation to a stationary solution of an autoregressive log-linear process process:
      param_start$past_obs <- sign(param_start$past_obs)*pmin(abs(param_start$past_obs), rep(1-slackvar-epsilon, p)) #beta_i in[-1+slackvar+epsilon, 1-slackvar-epsilon]
      param_start$past_mean <- sign(param_start$past_mean)*pmin(abs(param_start$past_mean), rep(1-slackvar-epsilon, q)) #alpha_i in [-1+slackvar+epsilon, 1-slackvar-epsilon]
    
      total <- sum(param_start$past_obs)+sum(param_start$past_mean)
      if(abs(total) > 1-epsilon-slackvar){ #Shrink the parameters to fulfill the stationarity condition if necessary:
        shrinkage_factor <- (1-slackvar-epsilon)/abs(total) #chosen, such that total_new = 1-slackvar-epsilon for total_new the sum of the alpha's and beta's after shrinkage
        param_start$past_mean <- param_start$past_mean*shrinkage_factor
        param_start$past_obs <- param_start$past_obs*shrinkage_factor
        ##the start estimation of the intercept is not corrected such that the resulting model has the same marginal mean as before the correction step, as it is done for the INGARCH model
      }  
    }
  }
  # # # # # # #
    
  paramvec_start <- unlist(param_start)
  names(paramvec_start) <- parameternames
  # # # # # # #
  durations["start"] <- proc.time()["elapsed"] - begin_start
  if(is.null(final.control)){
      durations["total"] <- proc.time()["elapsed"] - begin_total
      result <- list(start=paramvec_start, call=cl, n_obs=n, durations=durations, ts=ts, model=model, xreg=xreg) 
  return(result)      
  }
  ##############
  
  ##############
  #Final estimation:
  
  # # # # # # #
  #Create some functions as wrappers:
    f <- function(paramvec, model, xreg) tsglm.loglik(paramvec=paramvec, model=model, ts=ts, xreg=xreg, link=link, score=FALSE, info="none", init.method=init.method, init.drop=init.drop)$loglik    
    grad <- function(paramvec, model, xreg) tsglm.loglik(paramvec=paramvec, model=model, ts=ts, xreg=xreg, link=link, score=TRUE, info="none", init.method=init.method, init.drop=init.drop)$score
    optimisation <- function(starting_value, model, xreg, arguments){  
      if(!is.null(arguments$constrained)){
        if(link=="identity"){
          ui <- rbind(diag(1+p+q+r), c(0, rep(-1,p+q), rep(0, r)))
          ci <- c(slackvar, rep(0, p+q+r), -1+slackvar)
         }
         if(link=="log"){
          ui <- -cbind(rep(0, 2*(p+q)+2), rbind(+diag(p+q), -diag(p+q), rep(+1, p+q), rep(-1, p+q)), matrix(0, ncol=r, nrow=2*(p+q)+2))
          ci <- rep(-1+slackvar, 2*(p+q)+2)          
         } 
        optim_result <- do.call(constrOptim, args=c(list(theta=starting_value, f=f, grad=grad, ui=ui, ci=ci, method=arguments$optim.method, control=c(list(fnscale=-1), arguments$optim.control), model=model, xreg=xreg), arguments$constrained))
      }else{
        optim_result <- optim(par=starting_value, fn=f, gr=grad, model=model, xreg=xreg, method=arguments$optim.method, control=c(list(fnscale=-1), arguments$optim.control))
      }
      return(optim_result)
    }
  # # # # # # #
  
  if(is.null(inter.control)){ #no additional optimisation step is done
    inter_optim <- NULL
    durations["final"] <- system.time(final_optim <- optimisation(starting_value=paramvec_start, model=model, xreg=xreg, arguments=final.control))["elapsed"]
  }else{ #an additional optimisation step between start estimation and final optimisation is introduced
    durations["inter"] <- system.time(inter_optim <- optimisation(starting_value=paramvec_start, model=model, xreg=xreg, arguments=inter.control))["elapsed"]
    durations["final"] <- system.time(final_optim <- optimisation(starting_value=inter_optim$par, model=model, xreg=xreg, arguments=final.control))["elapsed"]
  }
  paramvec_inter <- as.numeric(inter_optim$par)
  paramvec_final <- as.numeric(final_optim$par)
  if(p+q+r>0 && all(abs((paramvec_final-paramvec_start)/paramvec_final) < 0.01)) warning("Final estimation is still very close to start estimation. This might indicate a\nproblem with the optimisation but could also have happended by chance. Please\ncheck results carefully.")
  if(p+q>0 && mean(abs(paramvec_final[c(1+P,1+p+Q)])) < 1e-04) warning("There is almost no serial dependence estimated in the data. This might be\nappropriate but could just as likely indicate a problem with the optimisation. Please check\nresults carefully.")
  if(sum(paramvec_final[c(1+P, 1+p+Q)])>1-slackvar-epsilon) warning("The sum of the estimated serial dependence parameters is very close to the\nboundary value one. This is a plausible estimation in the presence of very\nstrong serial dependence. However, this could also point to a nonstationarity\nof the process which has not been taken into account, e.g. a trend. Please\n check results carefully.") #For the log-link: Reaching the other (negative) boundaries of the parameter space for the serial dependence parameters does not trigger a warning. It is expected that this will rarely happen in practical applications.
  if(link=="identity") if(any(paramvec_final[1+p+q+R]<=epsilon)) warning("At least one estimated parameter corresponding to a covariate is very close to\nzero, the boundary of the parameter constraint for this parameter. This might\nbe an appropriate estimation but could also indicate that the parameter is\nactually negative and the chosen model is too restrictive. In such a case one\ncould consider using a model with the logarithmic link function. Please check\nresults carefully.")
  if(link=="identity") if(paramvec_final[1] < 0.1) warning("Estimated intercept is very small (< 0.1). This might indicate a problem with\nthe optimisation unless the observed marginal mean is very low or the observed\nserial dependence is very strong. Please check results carefully.")
  if(link=="log") if(abs(paramvec_final[1]) < log(0.1)) warning("Estimated absolute intercept is very small (< log(0.1)). This might indicate a\nproblem with the optimisation unless the observed marginal mean is very low or\nthe observed serial dependence is very strong. Please check results carefully.")

  ##############  
  
  ##############
  #Score vector and information matrix:
  #If score==FALSE and info=="none" the computation in the following two lines would not be necessary. However, the extra time needed to re-calculate the log-likelihood function which is already available in final_optim$value is negligable in comparison to the total duration of the function. This avoids some additional if-statements and the code is more readable.
  condmean <- tsglm.condmean(paramvec=paramvec_final, model=model, ts=ts, xreg=xreg, link=link, derivatives={if(!score & info=="none") "none" else if(info %in% c("hessian", "sandwich")) "second" else "first"}, init.method=init.method)
  loglik <- tsglm.loglik(paramvec=paramvec_final, model=model, ts=ts, xreg=xreg, link=link, score=score, info=info, condmean=condmean, from=Inf, init.drop=init.drop) #because of argument from=Inf no re-calculation of the recursion is done, instead the calculations from object condmean are used
  ##############

  ##############
  #Output preparation:   
  n_eff <- length(loglik$nu) #effective number of observations used for maximum likelihood estimation (excluding those only used for initialization when argument init.drop=TRUE)
  index_eff <- (n-n_eff+1):n #indices of those observations
  ts_eff <- ts[index_eff]
  #xreg_eff <- xreg[index_eff, , drop=FALSE]
  
  if(is.ts(ts)){ #use time series information for output if available from the input time series
    frqcy <- tsp(ts)[3]
    strt_original <- tsp(ts)[1]
    strt_eff <- strt_original+(n-n_eff)*1/frqcy 
    ts_eff <- ts(ts_eff, start=strt_eff, frequency=frqcy)
    loglik$nu <- ts(loglik$nu, start=strt_eff, frequency=frqcy)
  }
    
  durations["total"] <- proc.time()["elapsed"] - begin_total 
  result <- c(list(coefficients=final_optim$par, start=paramvec_start, inter=inter_optim, final=final_optim, residuals=ts_eff-g_inv(loglik$nu, link=link), fitted.values=g_inv(loglik$nu, link=link), linear.predictors=loglik$nu, response=ts_eff, logLik=loglik$loglik, score=loglik$score, info.matrix=loglik$info, outerscoreprod=loglik$outerscoreprod, call=cl, n_obs=n, n_eff=n_eff, durations=durations, ts=ts, model=model, xreg=xreg))
  return(result)
}
